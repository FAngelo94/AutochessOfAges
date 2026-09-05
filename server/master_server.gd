extends SceneTree

## Master server — coda + matchmaking (MULTIPLAYER_PLAN.md M4).
##
##   godot --headless --path . --script res://server/master_server.gd -- --port=9000
##
## WebSocketMultiplayerPeer usato come peer GREZZO (poll / get_packet /
## set_target_peer), non SceneMultiplayer/@rpc: il protocollo e' un comando
## esplicito da validare. Tutta la logica sta in Matchmaker, testabile in-process
## (tests/net_smoke.gd); questo script e' solo la pompa di frame + i socket.
##
## Una Matchmaker gestisce UNA lobby: quando si sigilla ne va aperta un'altra per
## i nuovi arrivi. Qui si tiene la lobby aperta corrente (_mm) piu' quelle
## sigillate di recente (_sealed_mms) finche' i loro client non si spostano sul
## worker.

const DEFAULT_PORT := 9000
const WORKER_CONTROL_URL := "ws://127.0.0.1:9001/ws/w1"

## Quanto tenere in vita una lobby sigillata (i client ricevono MATCH_ASSIGNED e
## si riconnettono al worker; poi si scollegano dal master).
const SEALED_LINGER_SECONDS := 20.0

var _peer := WebSocketMultiplayerPeer.new()
var _mm: Matchmaker
var _sealed_mms: Array = []          # [{mm, age}]
var _peer_mm: Dictionary = {}        # peer_id -> Matchmaker
## Verifica dei token di SESSIONE emessi da questo stesso master (HMAC locale,
## nessuna JWKS da scaricare). Iniettato in ogni Matchmaker.
var _verifier := SessionVerifier.new()
var _spawn := SpawnChannel.new(WORKER_CONTROL_URL)
var _pump: Node
var _bootstrapped := false
var _pending_close: Array = []

## Quante partite di cronologia si servono per default e al massimo. Il tetto
## e' del server: il client puo' chiedere, non decidere.
const HISTORY_DEFAULT := 20
const HISTORY_MAX := 50

## Tentativi di login falliti per email. Serve a rendere inutile provare le
## password a raffica: la chiave e' l'email e non il peer perche' il client apre
## una connessione nuova a ogni richiesta (net/auth.gd).
const LOGIN_MAX_FAILS := 8
const LOGIN_WINDOW := 300.0
var _login_fails: Dictionary = {}     # email_lower -> {count: int, first: float}


func _initialize() -> void:
	GameData.ensure_loaded()
	var port := _arg_int("port", DEFAULT_PORT)

	_mm = _new_matchmaker()

	var err := _peer.create_server(port)
	if err != OK:
		push_error("master: impossibile ascoltare sulla porta %d (err %d)" % [port, err])
		quit(1)
		return

	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)

	print("master: in ascolto su ws://127.0.0.1:%d  (rotta Caddy: /ws/mm)" % port)


func _new_matchmaker() -> Matchmaker:
	var mm := Matchmaker.new(_verifier)
	mm.spawn_requested.connect(_on_spawn_requested)
	mm.sealed.connect(_on_mm_sealed.bind(mm))
	mm.hero_review.connect(_on_hero_review)
	return mm


func _on_peer_connected(id: int) -> void:
	_peer_mm[id] = _mm
	_mm.handle_connect(id)


func _on_peer_disconnected(id: int) -> void:
	var mm: Matchmaker = _peer_mm.get(id, _mm)
	mm.handle_disconnect(id)
	_peer_mm.erase(id)


func _process(delta: float) -> bool:
	if not _bootstrapped:
		_bootstrapped = true
		_pump = Node.new()
		root.add_child(_pump)
		if not GoogleOAuth.is_configured():
			push_warning("master: GOOGLE_CLIENT_ID/SECRET assenti — login Google non disponibile (solo ospiti dev)")
		if not DbClient.is_configured():
			push_warning("master: DB_API_URL assente — nessuna persistenza (solo ospiti dev)")

	_spawn.poll()
	_peer.poll()

	while _peer.get_available_packet_count() > 0:
		var from := _peer.get_packet_peer()
		var bytes := _peer.get_packet()
		# I messaggi di autenticazione sono asincroni (HTTP verso Google e
		# PostgREST) e non riguardano la coda: li gestisce il master, non la
		# Matchmaker sincrona.
		var pre := Protocol.decode(bytes)
		var pt := Protocol.message_type(pre)
		if pt == Protocol.AUTH_GOOGLE or pt == Protocol.AUTH_REFRESH \
				or pt == Protocol.AUTH_EMAIL_LOGIN or pt == Protocol.AUTH_EMAIL_SIGNUP \
				or pt == Protocol.PROFILE_SET or pt == Protocol.DELETE_ACCOUNT \
				or pt == Protocol.HISTORY_REQUEST:
			_handle_auth(from, pt, pre)
			continue
		var mm: Matchmaker = _peer_mm.get(from, _mm)
		mm.handle_packet(from, bytes)

	_flush_outbox()
	_mm.tick(delta)
	_tick_sealed(delta)
	_flush_outbox()
	_apply_pending_close()
	return false


## Drena l'outbox della lobby aperta e di quelle sigillate ancora vive.
func _flush_outbox() -> void:
	_flush_one(_mm)
	for entry in _sealed_mms:
		_flush_one(entry.mm)


func _flush_one(mm: Matchmaker) -> void:
	for item in mm.pending_outbox():
		var bytes: PackedByteArray = Protocol.encode(item.msg)
		for pid in item.peers:
			_peer.set_target_peer(pid)
			_peer.put_packet(bytes)
			if item.close:
				_pending_close.append(pid)


func _tick_sealed(delta: float) -> void:
	for i in range(_sealed_mms.size() - 1, -1, -1):
		var entry: Dictionary = _sealed_mms[i]
		entry.mm.tick(delta)
		entry.age += delta
		if entry.age >= SEALED_LINGER_SECONDS:
			# i peer superstiti di questa lobby tornano alla lobby aperta
			for pid in _peer_mm.keys():
				if _peer_mm[pid] == entry.mm:
					_peer_mm[pid] = _mm
			_sealed_mms.remove_at(i)
	_purge_login_fails()


## Stessa manutenzione periodica delle lobby sigillate: evita che il dizionario
## dei tentativi falliti cresca senza limite.
func _purge_login_fails() -> void:
	var now := _now()
	for key in _login_fails.keys():
		var entry: Dictionary = _login_fails[key]
		if now - float(entry["first"]) > LOGIN_WINDOW:
			_login_fails.erase(key)


func _on_mm_sealed(mm: Matchmaker) -> void:
	if mm != _mm:
		return
	_sealed_mms.append({"mm": mm, "age": 0.0})
	_mm = _new_matchmaker()
	print("master: lobby sigillata, nuova lobby aperta")


## Chiusura rimandata di un frame: dà tempo al pacchetto REJECTED di partire
## prima che il socket venga chiuso.
func _apply_pending_close() -> void:
	var to_close := _pending_close
	_pending_close = []
	for pid in to_close:
		_peer.disconnect_peer(pid)


func _on_spawn_requested(payload: Dictionary) -> void:
	# Il worker riceve questo su WORKER_CONTROL_URL, verifica payload.spawn_sig
	# (HMAC MATCH_TOKEN_SECRET) e crea il MatchRunner.
	print("master: SPAWN_MATCH %s  seed=%d  ranked=%s" % [
		payload.get("match_id", "?"), int(payload.get("seed", 0)), payload.get("ranked", false)])
	_spawn.send(payload)


## Rivalidazione asincrona dell'hero contro owned_civs (l'id è già sanificato in
## Matchmaker). Enforce solo con MASTER_ENFORCE_ROSTER=1 — nel design attuale
## l'origin dell'hero è puramente estetica (palette del modello), quindi di norma
## si logga soltanto. Se in futuro gli eroi diventano legati alla civiltà, o con
## roster_mode "owned", basta accendere la variabile.
func _on_hero_review(uid: String, hero_id: String) -> void:
	if not DbClient.is_configured():
		return
	var hero := GameData.hero(hero_id)
	if hero == null or hero.origin == "":
		return
	var origin := hero.origin
	var enforce := OS.get_environment("MASTER_ENFORCE_ROSTER") == "1"
	DbClient.fetch_owned_civs(_pump, uid, func(ok: bool, civs: PackedStringArray) -> void:
		if not ok:
			return  # errore di rete: non declassare
		if civs.has(origin):
			return
		if enforce:
			push_warning("master: uid %s ha dichiarato hero '%s' (civ '%s') non posseduta — declassato" % [uid, hero_id, origin])
			_mm.override_hero(uid, GameData.DEFAULT_HERO_ID)
			for entry in _sealed_mms:
				entry.mm.override_hero(uid, GameData.DEFAULT_HERO_ID)
		else:
			print("master: nota — uid %s hero '%s' civ '%s' non in owned_civs (enforce off)" % [uid, hero_id, origin]))


# --------------------------------------------------------------------------
# Autenticazione (AUTH_GOOGLE / AUTH_REFRESH / PROFILE_SET)
# --------------------------------------------------------------------------

func _handle_auth(peer_id: int, msg_type: String, msg: Dictionary) -> void:
	match msg_type:
		Protocol.AUTH_GOOGLE:
			AccountService.login_google(_pump,
				String(msg.get("code", "")),
				String(msg.get("code_verifier", "")),
				String(msg.get("redirect_uri", "")),
				func(ok: bool, bundle: Dictionary) -> void: _reply_auth(peer_id, ok, bundle))
		Protocol.AUTH_REFRESH:
			AccountService.refresh(_pump, String(msg.get("refresh_token", "")),
				func(ok: bool, bundle: Dictionary) -> void: _reply_auth(peer_id, ok, bundle))
		Protocol.AUTH_EMAIL_LOGIN:
			var email := String(msg.get("email", ""))
			if _rate_limited(email):
				_reply(peer_id, Protocol.make(Protocol.AUTH_FAIL, {"reason": "rate_limited"}))
				return
			AccountService.login_email(_pump, email, String(msg.get("password", "")),
				func(ok: bool, bundle: Dictionary) -> void:
					_note_attempt(email, ok)
					_reply_auth(peer_id, ok, bundle))
		Protocol.AUTH_EMAIL_SIGNUP:
			AccountService.register_email(_pump,
				String(msg.get("email", "")),
				String(msg.get("password", "")),
				String(msg.get("username", "")),
				func(ok: bool, bundle: Dictionary) -> void: _reply_auth(peer_id, ok, bundle))
		Protocol.PROFILE_SET:
			var claims: Dictionary = _verifier.verify(String(msg.get("session_token", "")))
			if claims.is_empty():
				_reply(peer_id, Protocol.make(Protocol.AUTH_FAIL, {"reason": "auth"}))
				return
			DbClient.update_preferences(_pump, String(claims.get("sub", "")), {
				"favourite_origin": String(msg.get("favourite_origin", "")),
				"favourite_hero": String(msg.get("favourite_hero", "")),
			}, func(_ok: bool) -> void: _reply(peer_id, Protocol.make(Protocol.PROFILE_OK)))
		Protocol.HISTORY_REQUEST:
			var hist_claims: Dictionary = _verifier.verify(String(msg.get("session_token", "")))
			if hist_claims.is_empty():
				_reply(peer_id, Protocol.make(Protocol.AUTH_FAIL, {"reason": "auth"}))
				return
			# Il limite lo decide il server: un client che ne chiede centomila non
			# deve poter far costruire a Postgres una risposta enorme.
			var limit := clampi(int(msg.get("limit", HISTORY_DEFAULT)), 1, HISTORY_MAX)
			DbClient.fetch_match_history(_pump, String(hist_claims.get("sub", "")), limit,
				func(ok: bool, matches: Array) -> void:
					# Database irraggiungibile: si dice, non si finge una
					# cronologia vuota. La schermata distingue i due casi
					# ("nessuna partita" vs "non raggiungibili").
					if not ok:
						_reply(peer_id, Protocol.make(Protocol.AUTH_FAIL, {"reason": "db"}))
						return
					_reply(peer_id, Protocol.make(Protocol.HISTORY_DATA, {"matches": matches})))
		Protocol.DELETE_ACCOUNT:
			var del_claims: Dictionary = _verifier.verify(String(msg.get("session_token", "")))
			if del_claims.is_empty():
				_reply(peer_id, Protocol.make(Protocol.AUTH_FAIL, {"reason": "auth"}))
				return
			DbClient.delete_account(_pump, String(del_claims.get("sub", "")), func(ok: bool) -> void:
				if ok:
					_reply(peer_id, Protocol.make(Protocol.ACCOUNT_DELETED))
				else:
					_reply(peer_id, Protocol.make(Protocol.AUTH_FAIL, {"reason": "db"})))


## Non protegge da chi cambia email a ogni tentativo: rallenta la forza bruta
## contro UN account, che è l'attacco a costo più basso da fare.
func _rate_limited(email: String) -> bool:
	var key := email.to_lower().strip_edges()
	var entry: Dictionary = _login_fails.get(key, {})
	if entry.is_empty():
		return false
	if _now() - float(entry["first"]) > LOGIN_WINDOW:
		_login_fails.erase(key)
		return false
	return int(entry["count"]) >= LOGIN_MAX_FAILS


func _note_attempt(email: String, ok: bool) -> void:
	var key := email.to_lower().strip_edges()
	if ok:
		_login_fails.erase(key)
		return
	var entry: Dictionary = _login_fails.get(key, {"count": 0, "first": _now()})
	if _now() - float(entry["first"]) > LOGIN_WINDOW:
		entry = {"count": 0, "first": _now()}
	entry["count"] = int(entry["count"]) + 1
	_login_fails[key] = entry


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _reply_auth(peer_id: int, ok: bool, bundle: Dictionary) -> void:
	if ok:
		_reply(peer_id, Protocol.make(Protocol.AUTH_OK, bundle))
	else:
		_reply(peer_id, Protocol.make(Protocol.AUTH_FAIL, {"reason": String(bundle.get("reason", "auth"))}))


func _reply(peer_id: int, msg: Dictionary) -> void:
	_peer.set_target_peer(peer_id)
	_peer.put_packet(Protocol.encode(msg))


func _arg_int(name: String, def: int) -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return int(a.get_slice("=", 1))
	return def
