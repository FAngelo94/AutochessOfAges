class_name Matchmaker
extends RefCounted

## Il cuore del master server, isolato dai socket per essere testabile in-process
## (MULTIPLAYER_PLAN.md M4). master_server.gd e' solo la pompa di frame che gli
## passa i pacchetti in arrivo e drena la sua outbox verso i peer WebSocket.
##
## Flusso (§M4):
##  1. peer connesso -> attende HELLO {protocol_version, access_token};
##     versione errata     -> REJECTED{version} + chiusura;
##     token di sessione non valido -> REJECTED{auth} + chiusura;
##     ok                  -> WELCOME {user_id, username, stats}.
##  2. QUEUE_JOIN {hero_id} -> in coda (l'hero andra' rivalidato sul DB: TODO M4).
##  3. QUEUE_UPDATE {players, seconds_left} in broadcast ~1/s.
##  4. al sigillo (8 giocatori OPPURE 30 s dal primo in coda):
##     slot riempiti a 8 con bot, seed esplicito non-zero, ranked = humans >= 2,
##     SPAWN_MATCH al worker (segnale spawn_requested), MATCH_ASSIGNED a ogni
##     client in coda.

const SEAL_SECONDS := 30.0
const MAX_PLAYERS := 8
const QUEUE_UPDATE_INTERVAL := 1.0

## Un match con meno di 2 umani non conta per l'MMR: 1 umano + 7 bot -> ranked=false.
const RANKED_MIN_HUMANS := 2

## Con 1 solo worker la rotta e' sempre questa (Caddy, rotte statiche).
const WORKER_PATH := "/ws/w1"

## SPAWN_MATCH da mandare al worker sul canale di controllo interno.
signal spawn_requested(payload: Dictionary)

## Emesso quando la lobby si sigilla. Il master lo usa per aprirne una nuova
## (una sola Matchmaker resterebbe sigillata per sempre — MULTIPLAYER_PLAN.md M4).
signal sealed

## Emesso all'ingresso in coda, dopo la sanificazione sincrona dell'hero. Il
## master può fare un controllo asincrono su owned_civs (via DbClient/PostgREST)
## e poi chiamare override_hero() prima del sigillo.
signal hero_review(uid: String, hero_id: String)

## Iniettabile: qualunque oggetto con verify(token: String) -> Dictionary.
var verifier

## Se != 0, usato come seed della partita invece di uno casuale (test).
var force_seed: int = 0

var _peers: Dictionary = {}          # peer_id -> {uid, username}
var _queue: Array = []               # ordinato: [{peer_id, uid, hero_id, username}]
var _timer_left := 0.0
var _timer_running := false
var _update_accum := 0.0
var _sealed := false
var _last_seal: Dictionary = {}
var _outbox: Array = []              # [{peers: Array[int], msg: Dictionary, close: bool}]
var _rng := RandomNumberGenerator.new()


func _init(token_verifier = null) -> void:
	verifier = token_verifier
	_rng.randomize()


# --- API per master_server.gd ---------------------------------------------

func handle_connect(_peer_id: int) -> void:
	pass  # nulla finche' non arriva HELLO


func handle_disconnect(peer_id: int) -> void:
	_peers.erase(peer_id)
	_drop_from_queue(peer_id)


func handle_packet(peer_id: int, bytes: PackedByteArray) -> void:
	if bytes.size() > Protocol.MAX_PACKET_BYTES:
		_send(peer_id, Protocol.make(Protocol.REJECTED, {"reason": "oversize"}), true)
		return
	var msg := Protocol.decode(bytes)
	if msg.is_empty():
		return  # malformato: ignorato, mai un crash
	match Protocol.message_type(msg):
		Protocol.HELLO:
			_on_hello(peer_id, msg)
		Protocol.QUEUE_JOIN:
			_on_queue_join(peer_id, msg)
		Protocol.QUEUE_LEAVE:
			_drop_from_queue(peer_id)
			_broadcast_queue_update()
		_:
			pass


## Avanza il timer di sigillo. delta iniettato dal chiamante (test deterministico).
func tick(delta: float) -> void:
	if _sealed or not _timer_running:
		return
	_timer_left -= delta
	_update_accum += delta
	if _update_accum >= QUEUE_UPDATE_INTERVAL:
		_update_accum = fmod(_update_accum, QUEUE_UPDATE_INTERVAL)
		_broadcast_queue_update()
	if _timer_left <= 0.0:
		_seal()


## Drena i messaggi in uscita accumulati. Ogni voce: {peers, msg, close}.
func pending_outbox() -> Array:
	var out := _outbox
	_outbox = []
	return out


func size() -> int:
	return _queue.size()


func entries() -> Array:
	return _queue.duplicate(true)


func seconds_left() -> int:
	return int(ceil(max(0.0, _timer_left))) if _timer_running else 0


func is_sealed() -> bool:
	return _sealed


func last_seal() -> Dictionary:
	return _last_seal


# --- interno --------------------------------------------------------------

func _on_hello(peer_id: int, msg: Dictionary) -> void:
	if int(msg.get("protocol_version", 0)) != Protocol.PROTOCOL_VERSION:
		_send(peer_id, Protocol.make(Protocol.REJECTED, {"reason": "version"}), true)
		return
	var token := String(msg.get("access_token", ""))
	var claims: Dictionary = {}
	if verifier != null:
		claims = verifier.verify(token)
	if claims.is_empty() and OS.get_environment("MASTER_DEV_GUEST") == "1" \
			and token.begins_with(DevNet.GUEST_PREFIX):
		claims = {"sub": token, "username": "Ospite-" + token.substr(DevNet.GUEST_PREFIX.length())}
	if claims.is_empty():
		_send(peer_id, Protocol.make(Protocol.REJECTED, {"reason": "auth"}), true)
		return
	var uid := String(claims.get("sub", ""))
	var username := String(claims.get("username",
		claims.get("name", "player_%s" % uid.substr(0, 8))))
	_peers[peer_id] = {"uid": uid, "username": username}
	_send(peer_id, Protocol.make(Protocol.WELCOME, {
		"user_id": uid,
		"username": username,
		"stats": _stub_stats(),
	}))


func _on_queue_join(peer_id: int, msg: Dictionary) -> void:
	if not _peers.has(peer_id):
		# QUEUE_JOIN prima di un HELLO riuscito.
		_send(peer_id, Protocol.make(Protocol.REJECTED, {"reason": "auth"}), true)
		return
	if _sealed or _in_queue(peer_id):
		return
	var info: Dictionary = _peers[peer_id]
	# Rivalidazione dell'hero. Livello 1, sincrono e sempre attivo: l'id deve
	# esistere in data/heroes.json, altrimenti il worker andrebbe in errore
	# assegnandolo. Livello 2, asincrono e opzionale: il master, su hero_review,
	# rilegge owned_civs via DbClient (PostgREST) e può declassare via
	# override_hero() (vedi master_server.gd).
	var hero_id := _sanitize_hero(String(msg.get("hero_id", "")))
	_queue.append({
		"peer_id": peer_id,
		"uid": info.uid,
		"hero_id": hero_id,
		"username": info.username,
	})
	hero_review.emit(info.uid, hero_id)
	if not _timer_running:
		_timer_running = true
		_timer_left = SEAL_SECONDS
		_update_accum = 0.0
	_broadcast_queue_update()
	if _queue.size() >= MAX_PLAYERS:
		_seal()


## Sostituisce l'hero di ogni voce in coda con quell'uid. No-op dopo il sigillo
## (gli slot sono già stati costruiti). Usato dal controllo asincrono su owned_civs.
func override_hero(uid: String, hero_id: String) -> void:
	if _sealed:
		return
	var clean := _sanitize_hero(hero_id)
	for q in _queue:
		if q.uid == uid:
			q.hero_id = clean


func _sanitize_hero(hero_id: String) -> String:
	if hero_id != "" and GameData.hero_ids().has(hero_id):
		return hero_id
	return GameData.DEFAULT_HERO_ID


func _seal() -> void:
	if _sealed:
		return
	_sealed = true
	_timer_running = false

	var human_count := _queue.size()
	var seed_value := force_seed if force_seed != 0 else (_rng.randi() | 1)
	var match_id := "m_%x_%x" % [Time.get_ticks_usec(), _rng.randi()]

	var slots: Array = []
	for i in MAX_PLAYERS:
		if i < _queue.size():
			var q: Dictionary = _queue[i]
			slots.append({
				"index": i, "kind": "human",
				"uid": q.uid, "hero_id": q.hero_id, "username": q.username,
			})
		else:
			slots.append({
				"index": i, "kind": "bot",
				"uid": "", "hero_id": "", "username": "Bot %d" % i,
			})

	var ranked := human_count >= RANKED_MIN_HUMANS

	var spawn := Protocol.make(Protocol.SPAWN_MATCH, {
		"match_id": match_id,
		"seed": seed_value,
		"slots": slots,
		"ranked": ranked,
		"worker_path": WORKER_PATH,
	})
	# Firma HMAC: il worker rifiuta gli SPAWN_MATCH non firmati dal master.
	spawn["spawn_sig"] = MatchToken.sign_control(spawn)
	spawn_requested.emit(spawn)

	var now := int(Time.get_unix_time_from_system())
	for q in _queue:
		_send(q.peer_id, Protocol.make(Protocol.MATCH_ASSIGNED, {
			"match_id": match_id,
			"worker_path": WORKER_PATH,
			"match_token": MatchToken.mint(match_id, q.uid, now),
			"seed": seed_value,
		}))

	_last_seal = {
		"match_id": match_id,
		"seed": seed_value,
		"slots": slots,
		"ranked": ranked,
		"human_count": human_count,
	}

	sealed.emit()


func _broadcast_queue_update() -> void:
	if _queue.is_empty():
		return
	var msg := Protocol.make(Protocol.QUEUE_UPDATE, {
		"players": _queue.size(),
		"seconds_left": seconds_left(),
	})
	_outbox.append({"peers": _queue_peer_ids(), "msg": msg, "close": false})


func _send(peer_id: int, msg: Dictionary, close: bool = false) -> void:
	_outbox.append({"peers": [peer_id], "msg": msg, "close": close})


func _in_queue(peer_id: int) -> bool:
	for q in _queue:
		if q.peer_id == peer_id:
			return true
	return false


func _drop_from_queue(peer_id: int) -> void:
	for i in range(_queue.size() - 1, -1, -1):
		if _queue[i].peer_id == peer_id:
			_queue.remove_at(i)


func _queue_peer_ids() -> Array:
	var ids: Array = []
	for q in _queue:
		ids.append(q.peer_id)
	return ids


func _stub_stats() -> Dictionary:
	# M4: le statistiche reali arrivano da player_stats via service_role in M5.
	return {"matches_played": 0, "wins": 0, "top4": 0, "mmr": 1000}
