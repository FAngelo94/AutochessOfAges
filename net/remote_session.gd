class_name RemoteSession
extends MatchSession

## Sessione online (MULTIPLAYER_PLAN.md M6).
##
## Due WebSocketPeer grezzi in sequenza:
##   1. il master (wss://<host>/ws/mm) — coda e assegnazione partita
##   2. il worker (wss://<host>/ws/<worker_path>) — il match autoritativo
##
## Il client NON simula mai: `_state` e' un vero MatchState riempito solo dagli
## snapshot del server via apply_dict(), cosi' tutte le letture di ui/main.gd
## restano invariate. I comandi diventano pacchetti CMD_* da validare lato
## server; la UI vede il risultato solo quando torna il MATCH_STATE.
##
## RemoteSession e' RefCounted (come MatchSession) e non puo' stare nell'albero:
## un piccolo Node interno (_Poller) la pompa ogni frame. Chi la tiene viva
## (prima la lobby, poi ui/main.gd) chiama drive(self) per (ri)agganciare il
## poller — il cambio di scena distrugge il poller della lobby, main ne crea
## uno nuovo.

## Host non configurato in data/backend.json: la modalita' online e' spenta.
signal not_configured
## WELCOME dal master.
signal queue_welcome(username: String)
## QUEUE_UPDATE dal master: quanti in coda e secondi al via.
signal queue_updated(players: int, seconds_left: int)
## REJECTED dal master (version | auth | banned | ...).
signal queue_rejected(reason: String)
## MATCH_ASSIGNED ricevuto: la lobby puo' passare la sessione a ui/main.tscn.
signal match_assigned()
## Un nuovo round di preparazione col tempo rimasto (per il countdown remoto).
signal prep_started(prep_seconds: float)

const BACKEND_CONFIG := "res://data/backend.json"
const MAX_QUEUE_SLOTS := 8
const MAX_RECONNECT := 5

## Battito applicativo verso il worker (Protocol.PING/PONG). Senza questo, un
## socket che l'OS ha droppato in silenzio durante una sospensione in
## background continua a rispondere STATE_OPEN per sempre: ne' il client ne'
## il worker vedono mai un vero close-frame, quindi non scatterebbe nessuna
## riconnessione automatica — esattamente il "bloccato in preparazione" di
## partenza. Ogni pacchetto in arrivo (PONG compreso) conta come prova di vita.
const WORKER_PING_INTERVAL := 5.0
const WORKER_TIMEOUT := 15.0
## Al ritorno in primo piano si accorcia la grazia residua invece di aspettare
## fino a WORKER_TIMEOUT: se il socket era gia' morto lo si scopre in pochi
## secondi anziche' aspettare quanto resta del timeout pieno.
const RESUME_GRACE := 4.0

## Partita attiva ancora in corso quando il gioco viene chiuso (non solo messo
## in background): senza questo, riaprire il gioco riparte sempre dal menu e
## la partita resta agganciata solo lato server finche' non scade. Stesso
## schema di net/auth.gd (PENDING_PATH) per il consenso Google in sospeso.
const PENDING_MATCH_PATH := "user://match_pending.dat"

## Numero massimo di giocatori del match (per MatchState vuoto iniziale).
const MATCH_SLOTS := 8

var _state: MatchState
var _local_index: int = 0

var _host: String = ""
var _hero_id: String = ""
var _guest_id: String = ""

var _master: WebSocketPeer = null
var _worker: WebSocketPeer = null
var _hello_sent: bool = false
var _join_sent: bool = false
var _assigned: bool = false
var _in_match: bool = false
var _finished: bool = false
var _lost: bool = false

var _assignment: Dictionary = {}          # {match_id, match_token, worker_path}
var _reconnect_attempts: int = 0
var _pending_token: String = ""

var _last_worker_recv: float = 0.0
var _last_ping_sent: float = 0.0

## Ultimo combattimento e lato ricevuti (COMBAT) — riuniti in round_concluded.
var _own_combat: Dictionary = {}
var _own_team: int = 0

## Righe pubbliche dell'ultimo ROUND_CONCLUDED, di TUTTI i posti (_synth_results
## tiene solo la propria). Servono a can_spectate(): dicono chi ha combattuto
## davvero e chi ha avuto un round fantasma.
var _last_public_results: Array = []

## Tempo di preparazione rimasto, scalato localmente per il countdown.
var prep_seconds_left: float = 0.0

## Prossimo avversario comunicato dal server nell'ultimo MATCH_STATE, o -1: il
## client non accoppia, quindi questo dato può arrivare solo da fuori. Lo
## snapshot di fine combattimento non porta il campo e lo riazzera da sé.
var _next_opponent_index: int = -1

var _poller = null   # _Poller (untyped: it carries a `session` member Node lacks)


class _Poller extends Node:
	var session: RemoteSession
	func _process(delta: float) -> void:
		if session != null:
			session._poll(delta)
	func _notification(what: int) -> void:
		# I NOTIFICATION_* sono costanti di Node: RemoteSession e' RefCounted e
		# non le vede, il controllo va fatto qui.
		if session != null and (what == NOTIFICATION_APPLICATION_RESUMED
				or what == NOTIFICATION_WM_WINDOW_FOCUS_IN):
			session._on_app_resumed()


func _init() -> void:
	# Un MatchState vuoto perche' ui/main.gd possa disegnare qualcosa prima che
	# arrivi il primo snapshot. Verra' interamente sovrascritto da apply_dict().
	_state = MatchState.new(1, MATCH_SLOTS)


# --------------------------------------------------------------------------
# Ciclo di vita / pompa
# --------------------------------------------------------------------------

## (Ri)aggancia il poller al Node vivo che tiene la sessione.
func drive(host: Node) -> void:
	if _poller == null or not is_instance_valid(_poller):
		_poller = _Poller.new()
		_poller.name = "RemoteSessionPoller"
		_poller.session = self
		host.add_child(_poller)
	elif _poller.get_parent() != host:
		_poller.reparent(host)


func _stop_poller() -> void:
	if _poller != null and is_instance_valid(_poller):
		_poller.queue_free()
	_poller = null


# --------------------------------------------------------------------------
# Fase master (usata dalla lobby)
# --------------------------------------------------------------------------

## Avvia la connessione col master e l'ingresso in coda. hero_id e' quello
## dichiarato dal client (il server lo rivalida contro il DB).
func start_queue(hero_id: String) -> void:
	_hero_id = hero_id
	_host = _resolve_host()
	if _host == "" and not DevNet.enabled():
		not_configured.emit()
		connection_lost.emit("not configured")
		return

	_pending_token = ""
	if _poller != null and is_instance_valid(_poller):
		var auth: Node = _poller.get_node_or_null("/root/Auth")
		if auth != null:
			_pending_token = String(auth.access_token())
	if _pending_token == "" and DevNet.enabled():
		if _guest_id == "":
			_guest_id = "%s%d-%d" % [DevNet.GUEST_PREFIX, OS.get_process_id(), randi() % 100000]
		_pending_token = _guest_id

	_master = WebSocketPeer.new()
	_hello_sent = false
	var master_url := DevNet.master_url() if DevNet.enabled() else "wss://%s/ws/mm" % _host
	var err := _master.connect_to_url(master_url)
	if err != OK:
		_master = null
		connection_lost.emit("master unreachable")
		return


## Esce dalla coda e chiude la connessione col master.
func leave_queue() -> void:
	if _master != null:
		_send(_master, Protocol.make(Protocol.QUEUE_LEAVE))
		_master.close()
		_master = null
	_stop_poller()


func assignment() -> Dictionary:
	return _assignment


# --------------------------------------------------------------------------
# MatchSession — API per ui/main.gd
# --------------------------------------------------------------------------

## In remoto la partita esiste gia' sul server: begin() non fa nulla.
func begin(_match_seed: int = 0, _hero_id: String = "") -> void:
	pass


func state() -> MatchState:
	return _state


func local_index() -> int:
	return _local_index


func next_opponent_index() -> int:
	return _next_opponent_index


func request_buy(slot: int) -> void:
	_send_worker(Protocol.make(Protocol.CMD_BUY, {"slot": slot}))


func request_sell(uid: int) -> void:
	_send_worker(Protocol.make(Protocol.CMD_SELL, {"uid": uid}))


func request_reroll() -> void:
	_send_worker(Protocol.make(Protocol.CMD_REROLL))


func request_buy_xp() -> void:
	_send_worker(Protocol.make(Protocol.CMD_BUY_XP))


func request_move_to_board(uid: int, cell: Vector2i) -> void:
	_send_worker(Protocol.make(Protocol.CMD_MOVE_BOARD, {"uid": uid, "cell": cell}))


func request_move_to_bench(uid: int, slot: int) -> void:
	_send_worker(Protocol.make(Protocol.CMD_MOVE_BENCH, {"uid": uid, "slot": slot}))


func request_ready() -> void:
	_send_worker(Protocol.make(Protocol.READY))


func can_spectate(player_index: int) -> bool:
	for row in _last_public_results:
		var opp_idx := int(row.get("opponent_index", -1))
		# opponent_index < 0 == round a vuoto (unico caso senza log di combattimento).
		if int(row.get("player_index", -1)) == player_index:
			return opp_idx >= 0
		# Endpoint eliminato di un matchup fantasma: la battaglia c'è comunque.
		if bool(row.get("ghost", false)) and opp_idx == player_index:
			return true
	return false


func request_spectate(player_index: int) -> void:
	# Il proprio ultimo scontro è già in memoria (COMBAT): si serve subito senza
	# passare dal worker, che dopo la fine partita viene smontato (game_worker
	# FINISH_GRACE_MS) e non risponderebbe più — è il caso della lente nella
	# schermata di classifica.
	if player_index == _local_index and not _own_combat.is_empty():
		var opp_hero := ""
		for row in _last_public_results:
			if int(row.get("player_index", -1)) == _local_index:
				var opp_idx := int(row.get("opponent_index", -1))
				if opp_idx >= 0 and opp_idx < _state.players.size():
					opp_hero = _state.players[opp_idx].hero_id
				break
		spectate_ready.emit(_local_index, _own_combat, _own_team, opp_hero)
		return
	_send_worker(Protocol.make(Protocol.SPECTATE_REQUEST, {"player_index": player_index}))


## Abbandona: si arrende (il server azzera la vita del posto) e chiude tutto.
func leave() -> void:
	if _worker != null:
		_send_worker(Protocol.make(Protocol.SURRENDER))
		_worker.close()
		_worker = null
	if _master != null:
		_master.close()
		_master = null
	_in_match = false
	_forget_pending_match()
	_stop_poller()


## Vero se il gioco e' stato chiuso a meta' di una partita online ancora
## presumibilmente in corso (net/auth.gd usa lo stesso schema per il consenso
## Google in sospeso). ui/login.gd lo controlla prima di mostrare il login.
static func has_pending_match() -> bool:
	return not _load_pending_match().is_empty()


## Ricostruisce l'aggancio al worker da user://match_pending.dat invece che
## dalla coda: la partita esiste gia' sul server, si rientra direttamente.
## true se la connessione e' stata avviata (non garantisce che il JOIN sara'
## accettato — un match_token scaduto o un match gia' concluso arrivano come
## COMMAND_REJECTED/mancata risposta, gestiti come una riconnessione fallita).
func resume_from_pending() -> bool:
	var data := _load_pending_match()
	if data.is_empty():
		return false
	_host = String(data.get("host", ""))
	_assignment = {
		"match_id": data.get("match_id", ""),
		"match_token": data.get("match_token", ""),
		"worker_path": data.get("worker_path", "/ws/w1"),
		"host": _host,
		"seed": data.get("seed", 0),
	}
	_assigned = true
	_in_match = true
	return _open_worker() == OK


## Tentativo manuale di riconnessione (pulsante "Riconnetti").
func reconnect() -> void:
	if _finished:
		return
	_lost = false
	_reconnect_attempts = 0
	_open_worker()


# --------------------------------------------------------------------------
# Pompa
# --------------------------------------------------------------------------

func _poll(delta: float) -> void:
	if _state != null and _state.phase == MatchState.Phase.PREPARATION and prep_seconds_left > 0.0:
		prep_seconds_left = maxf(0.0, prep_seconds_left - delta)

	if _master != null:
		_master.poll()
		var ms := _master.get_ready_state()
		if ms == WebSocketPeer.STATE_OPEN:
			if not _hello_sent:
				_send(_master, Protocol.make(Protocol.HELLO, {
					"protocol_version": Protocol.PROTOCOL_VERSION,
					"access_token": _pending_token,
				}))
				_send(_master, Protocol.make(Protocol.QUEUE_JOIN, {"hero_id": _hero_id}))
				_hello_sent = true
			# Guardia su _master: _handle_master(MATCH_ASSIGNED) chiude il master e
			# lo azzera, mentre questo ciclo sta ancora iterando.
			while _master != null and _master.get_available_packet_count() > 0:
				_handle_master(Protocol.decode(_master.get_packet()))
		elif ms == WebSocketPeer.STATE_CLOSED:
			_master = null
			if not _assigned:
				connection_lost.emit("master closed")

	if _worker != null:
		_worker.poll()
		var ws := _worker.get_ready_state()
		if ws == WebSocketPeer.STATE_OPEN:
			if not _join_sent:
				_send(_worker, Protocol.make(Protocol.JOIN, {
					"match_id": _assignment.get("match_id", ""),
					"match_token": _assignment.get("match_token", ""),
				}))
				_join_sent = true
				_reconnect_attempts = 0
				_last_worker_recv = _now()
				_last_ping_sent = _now()
			# Stessa guardia: un handler (es. MATCH_FINISHED -> leave()) puo'
			# azzerare _worker durante il ciclo.
			while _worker != null and _worker.get_available_packet_count() > 0:
				_last_worker_recv = _now()
				_handle_worker(Protocol.decode(_worker.get_packet()))
			if _worker != null and _now() - _last_ping_sent >= WORKER_PING_INTERVAL:
				_last_ping_sent = _now()
				_send(_worker, Protocol.make(Protocol.PING))
			if _worker != null and _now() - _last_worker_recv > WORKER_TIMEOUT:
				# Zombie: il socket dice ancora "aperto" ma non risponde da
				# troppo tempo — succede quando l'OS sospende l'app in
				# background senza mai chiudere davvero il socket. Forza la
				# chiusura per rientrare nel ramo di riconnessione sotto.
				_worker.close()
				ws = WebSocketPeer.STATE_CLOSED
		if ws == WebSocketPeer.STATE_CLOSED:
			_worker = null
			if _in_match and not _finished and not _lost:
				_reconnect_attempts += 1
				if _reconnect_attempts <= MAX_RECONNECT:
					_open_worker()
				else:
					_lost = true
					connection_lost.emit("connessione persa")


# --------------------------------------------------------------------------
# Master
# --------------------------------------------------------------------------

func _handle_master(msg: Dictionary) -> void:
	if msg.is_empty():
		return
	match Protocol.message_type(msg):
		Protocol.WELCOME:
			queue_welcome.emit(String(msg.get("username", "")))
		Protocol.QUEUE_UPDATE:
			queue_updated.emit(int(msg.get("players", 0)), int(msg.get("seconds_left", 0)))
		Protocol.REJECTED:
			queue_rejected.emit(String(msg.get("reason", "")))
			if _master != null:
				_master.close()
				_master = null
		Protocol.MATCH_ASSIGNED:
			_assignment = {
				"match_id": msg.get("match_id", ""),
				"match_token": msg.get("match_token", ""),
				"worker_path": msg.get("worker_path", "/ws/w1"),
				"host": _host,
				"seed": msg.get("seed", 0),
			}
			_assigned = true
			_save_pending_match()
			if _master != null:
				_master.close()
				_master = null
			match_assigned.emit()
			_open_worker()


# --------------------------------------------------------------------------
# Worker
# --------------------------------------------------------------------------

func _open_worker() -> int:
	if _host == "":
		_host = String(_assignment.get("host", _resolve_host()))
	if _host == "" and not DevNet.enabled():
		_lost = true
		connection_lost.emit("not configured")
		return ERR_CANT_CONNECT
	_worker = WebSocketPeer.new()
	_join_sent = false
	var path := String(_assignment.get("worker_path", "/ws/w1"))
	var worker_url := DevNet.worker_url(path) if DevNet.enabled() else "wss://%s%s" % [_host, path]
	var err := _worker.connect_to_url(worker_url)
	if err != OK:
		_worker = null
		_lost = true
		connection_lost.emit("worker unreachable")
	return err


func _handle_worker(msg: Dictionary) -> void:
	if msg.is_empty():
		return
	match Protocol.message_type(msg):
		Protocol.MATCH_STATE:
			_in_match = true
			_local_index = int(msg.get("for_index", _local_index))
			var st: Dictionary = msg.get("state", {})
			if not st.is_empty():
				_state.apply_dict(st)
				_fix_local_seat()
			_next_opponent_index = int(msg.get("next_opponent_index", -1))
			state_changed.emit()
		Protocol.ROUND_STARTED:
			_state.stage = int(msg.get("stage", _state.stage))
			_state.round_index = int(msg.get("round_index", _state.round_index))
			_state.phase = MatchState.Phase.PREPARATION
			prep_seconds_left = float(msg.get("prep_seconds", 0.0))
			prep_started.emit(prep_seconds_left)
			round_started.emit(_state.stage, _state.round_index)
			state_changed.emit()
		Protocol.COMBAT:
			_own_team = int(msg.get("team", 0))
			_own_combat = _decode_combat(msg)
		Protocol.ROUND_CONCLUDED:
			_state.phase = MatchState.Phase.COMBAT
			_last_public_results = msg.get("results", [])
			round_concluded.emit(_synth_results(_last_public_results))
		Protocol.COMMAND_REJECTED:
			var reason := String(msg.get("reason", ""))
			if reason == "join_token" or reason == "join_seat":
				# Il nostro stesso JOIN e' stato rifiutato (token scaduto/match
				# sparito lato server): non ha senso ritentare, e la partita
				# ripresa dal disco non esiste piu'.
				_forget_pending_match()
				_lost = true
				if _worker != null:
					_worker.close()
					_worker = null
				connection_lost.emit("partita non più raggiungibile")
				return
			command_rejected.emit(reason)
		Protocol.MATCH_FINISHED:
			_finished = true
			_state.phase = MatchState.Phase.FINISHED
			_forget_pending_match()
			match_finished.emit(msg.get("standings", []))
		Protocol.RANK_UPDATE:
			_apply_rank_update(msg)
			rank_updated.emit(int(msg.get("mmr", 0)), int(msg.get("delta", 0)))
		Protocol.SPECTATE_DATA:
			spectate_ready.emit(
				int(msg.get("player_index", -1)),
				_decode_combat(msg),
				int(msg.get("team", 0)),
				String(msg.get("opponent_hero_id", "")))


## Aggiorna Auth.stats (se l'autoload c'e' — non nei test headless) cosi' il
## grado mostrato nel menu è già quello nuovo la prossima volta che lo si apre,
## senza aspettare un altro login. Stesso pattern di get_node_or_null usato in
## start_queue() per l'access token.
func _apply_rank_update(msg: Dictionary) -> void:
	if _poller == null or not is_instance_valid(_poller):
		return
	var auth: Node = _poller.get_node_or_null("/root/Auth")
	if auth == null:
		return
	auth.stats["mmr"] = int(msg.get("mmr", 0))
	auth.stats["matches_played"] = int(msg.get("matches_played", 0))
	auth.stats["wins"] = int(msg.get("wins", 0))
	auth.stats["top4"] = int(msg.get("top4", 0))


## I bot / gli altri umani non contano lato client: l'unico "umano" e' il posto
## locale, cosi' MatchState.human_player() (usato ovunque in ui/main.gd) torna
## sempre il posto giusto anche in una partita con piu' umani.
func _fix_local_seat() -> void:
	for i in _state.players.size():
		_state.players[i].is_bot = i != _local_index


## Ricostruisce la riga di risultato del giocatore locale nel formato che
## ui/main.gd si aspetta da resolve_round() (oggetti Player veri + combat).
func _synth_results(results_public: Array) -> Array:
	var out: Array = []
	for row in results_public:
		if int(row.get("player_index", -1)) != _local_index:
			continue
		var opp_idx := int(row.get("opponent_index", -1))
		var opponent: Player = null
		if opp_idx >= 0 and opp_idx < _state.players.size():
			opponent = _state.players[opp_idx]
		out.append({
			"player": _state.players[_local_index],
			"opponent": opponent,
			"won": bool(row.get("won", false)),
			"damage": int(row.get("damage", 0)),
			"damage_dealt": int(row.get("damage_dealt", 0)),
			"ghost": bool(row.get("ghost", false)),
			"team": _own_team,
			"combat": _own_combat,
		})
	return out


## COMBAT / SPECTATE_DATA: combat e' un dict grezzo, oppure — se zstd:true — un
## PackedByteArray compresso (Appendice A / match_runner._merge_combat).
func _decode_combat(msg: Dictionary) -> Dictionary:
	var c: Variant = msg.get("combat", {})
	if bool(msg.get("zstd", false)) and c is PackedByteArray:
		var raw: PackedByteArray = c
		var size := int(msg.get("combat_size", 0))
		var plain := raw.decompress(size, FileAccess.COMPRESSION_ZSTD)
		var v: Variant = bytes_to_var(plain)
		return v if v is Dictionary else {}
	return c if c is Dictionary else {}


# --------------------------------------------------------------------------
# Utilita'
# --------------------------------------------------------------------------

## Ritorno in primo piano (_Poller._notification): il socket puo' essere morto
## senza che l'OS l'abbia mai chiuso per davvero. Si accorcia la grazia residua
## invece di aspettare fino a WORKER_TIMEOUT — se e' ancora vivo il prossimo
## PING/risposta arriva comunque entro RESUME_GRACE e la si allunga di nuovo.
func _on_app_resumed() -> void:
	if _worker == null:
		return
	_last_ping_sent = 0.0
	_last_worker_recv = minf(_last_worker_recv, _now() - (WORKER_TIMEOUT - RESUME_GRACE))


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Salva l'aggancio alla partita attiva: se il gioco viene chiuso (non solo
## sospeso in background) e' l'unica cosa che permette di rientrare invece di
## ripartire dal menu. Cancellata a fine partita o su leave() esplicito.
func _save_pending_match() -> void:
	var f := FileAccess.open(PENDING_MATCH_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"match_id": _assignment.get("match_id", ""),
		"match_token": _assignment.get("match_token", ""),
		"worker_path": _assignment.get("worker_path", "/ws/w1"),
		"host": _assignment.get("host", _host),
		"seed": _assignment.get("seed", 0),
	}))
	f.close()


static func _load_pending_match() -> Dictionary:
	if not FileAccess.file_exists(PENDING_MATCH_PATH):
		return {}
	var f := FileAccess.open(PENDING_MATCH_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = parsed
	if String(d.get("match_id", "")) == "" or String(d.get("match_token", "")) == "":
		return {}
	return d


func _forget_pending_match() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(PENDING_MATCH_PATH.get_file()):
		dir.remove(PENDING_MATCH_PATH.get_file())


func _resolve_host() -> String:
	if not FileAccess.file_exists(BACKEND_CONFIG):
		return ""
	var f := FileAccess.open(BACKEND_CONFIG, FileAccess.READ)
	if f == null:
		return ""
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	var h := String((parsed as Dictionary).get("game_host", "")).strip_edges()
	if h == "":
		return ""
	var lower := h.to_lower()
	# Segnaposto tracciati nel repo: trattali come "non configurato".
	for placeholder in ["tuodominio", "your-", "yourdomain", "example.", "changeme", "placeholder"]:
		if placeholder in lower:
			return ""
	return h


func _send(peer: WebSocketPeer, msg: Dictionary) -> void:
	if peer != null and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		peer.put_packet(Protocol.encode(msg))


func _send_worker(msg: Dictionary) -> void:
	_send(_worker, msg)
