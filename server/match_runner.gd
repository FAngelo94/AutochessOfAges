class_name MatchRunner
extends RefCounted

## Il match autoritativo (MULTIPLAYER_PLAN.md M5). Possiede UN MatchState, scandisce
## i round a tempo, valida ogni comando client su tre livelli (identita' / fase /
## regole) e manda a ciascun giocatore solo cio' che gli spetta.
##
## Socket-free e testabile: si costruisce dal payload SPAWN_MATCH, riceve pacchetti
## via handle_packet(peer, bytes), avanza con tick(delta) a delta iniettato, e
## accumula i messaggi in uscita in pending_outbox() — esattamente lo schema di
## Matchmaker (M4). server/game_worker.gd e' solo la pompa di frame + i socket.

enum Phase { PREPARATION, COMBAT, FINISHED }

## Oltre questa dimensione (byte, combat serializzato) il log va compresso ZSTD.
const COMBAT_COMPRESS_THRESHOLD := 200_000
## Margine aggiunto alla durata del combattimento piu' lungo prima del round dopo.
const PACING_MARGIN := 2.0
## Salt per i BotBrain che rimpiazzano un umano disconnesso (stream separato:
## la riproducibilita' col seed vale solo per una partita senza disconnessioni).
const DISCONNECT_BRAIN_SALT := 0xD15C0

var match_id: String
var seed_value: int
var ranked: bool
var worker_path: String

var _state: MatchState
var _slots: Array = []                       # come da SPAWN_MATCH, ordinati per index
var _uid_to_seat: Dictionary = {}            # uid umano -> player_index
var _brains: Dictionary = {}                 # player_index -> BotBrain (bot + umani caduti)
var _disconnect_seats: Dictionary = {}       # player_index -> true se il brain e' un rimpiazzo

var _peer_seat: Dictionary = {}              # peer_id -> player_index
var _seat_peer: Dictionary = {}              # player_index -> peer_id

var _phase: int = Phase.PREPARATION
var _prep_left: float = 0.0
var _combat_wait: float = 0.0
var _ready: Dictionary = {}                  # player_index -> true
var _last_results: Array = []
var _pending_finish := false
var _finished := false
var _stats_owner: Node = null               # Node vivo per StatsWriter (opzionale)

var _outbox: Array = []


func _init(spawn_payload: Dictionary, stats_owner: Node = null) -> void:
	match_id = String(spawn_payload.get("match_id", ""))
	seed_value = int(spawn_payload.get("seed", 0))
	ranked = bool(spawn_payload.get("ranked", false))
	worker_path = String(spawn_payload.get("worker_path", ""))
	_stats_owner = stats_owner

	_slots = spawn_payload.get("slots", [])
	var human_count := 0
	for s in _slots:
		if String(s.get("kind", "")) == "human":
			human_count += 1
			_uid_to_seat[String(s.get("uid", ""))] = int(s.get("index", 0))

	_state = MatchState.new(seed_value, human_count)

	# Eroe degli umani: assegnato prima di costruire i bot (nessuna pescata RNG).
	for s in _slots:
		if String(s.get("kind", "")) == "human":
			var idx := int(s.get("index", 0))
			_state.players[idx].hero_id = String(s.get("hero_id", ""))
			_state.players[idx].display_name = String(s.get("username", _state.players[idx].display_name))

	# Bot: costruzione e albero RNG IDENTICI a net/local_session.gd. Non toccare
	# `seed_value ^ 0x5EED` ne' fork(p.index): il costruttore di BotBrain e' a
	# effetti collaterali e pesca in ordine fisso (core/bot_brain.gd:19).
	var brain_rng := SimRNG.new(_state.seed_value ^ 0x5EED)
	for p in _state.players:
		if p.is_bot:
			_brains[p.index] = BotBrain.new(p, brain_rng.fork(p.index))

	_state.start_round()
	_open_preparation(true)


# --------------------------------------------------------------------------
# API per game_worker.gd
# --------------------------------------------------------------------------

func handle_packet(peer_id: int, bytes: PackedByteArray) -> void:
	var msg := Protocol.decode(bytes)
	if msg.is_empty():
		return
	match Protocol.message_type(msg):
		Protocol.JOIN:
			_on_join(peer_id, msg)
		Protocol.READY:
			_on_ready(peer_id)
		Protocol.SURRENDER:
			_on_surrender(peer_id)
		Protocol.SPECTATE_REQUEST:
			_on_spectate(peer_id, msg)
		Protocol.CMD_BUY, Protocol.CMD_SELL, Protocol.CMD_REROLL, Protocol.CMD_BUY_XP, \
		Protocol.CMD_MOVE_BOARD, Protocol.CMD_MOVE_BENCH:
			_on_command(peer_id, msg)
		_:
			pass


func handle_disconnect(peer_id: int) -> void:
	if not _peer_seat.has(peer_id):
		return
	var idx: int = _peer_seat[peer_id]
	_peer_seat.erase(peer_id)
	_seat_peer.erase(idx)
	_ready.erase(idx)
	# Il posto NON viene eliminato: passa a un BotBrain per i round successivi.
	if not _brains.has(idx):
		var rng := SimRNG.new(_state.seed_value ^ DISCONNECT_BRAIN_SALT ^ idx)
		_brains[idx] = BotBrain.new(_state.players[idx], rng)
		_disconnect_seats[idx] = true


## Avanza il match. delta iniettato dal chiamante (test deterministico).
func tick(delta: float) -> void:
	if _finished:
		return
	if _phase == Phase.PREPARATION:
		_prep_left -= delta
		if _prep_left <= 0.0 or _all_live_humans_ready():
			_resolve_round()
	elif _phase == Phase.COMBAT:
		_combat_wait -= delta
		if _combat_wait <= 0.0:
			if _pending_finish:
				_finish_match()
			else:
				_state.start_round()
				_open_preparation(false)


func pending_outbox() -> Array:
	var out := _outbox
	_outbox = []
	return out


# --------------------------------------------------------------------------
# Accessori (test / worker)
# --------------------------------------------------------------------------

func state() -> MatchState:
	return _state

func phase() -> int:
	return _phase

func is_finished() -> bool:
	return _finished

func seat_reserved(index: int) -> bool:
	return index >= 0 and index < _state.players.size()

func peer_for_seat(index: int) -> int:
	return int(_seat_peer.get(index, -1))

func seat_has_peer(index: int) -> bool:
	return _seat_peer.has(index)


# --------------------------------------------------------------------------
# Ingresso / uscita
# --------------------------------------------------------------------------

func _on_join(peer_id: int, msg: Dictionary) -> void:
	var claims := MatchToken.verify(String(msg.get("match_token", "")))
	if claims.is_empty() or String(claims.get("match_id", "")) != match_id:
		_send(peer_id, Protocol.make(Protocol.COMMAND_REJECTED, {"reason": "join_token"}))
		return
	var uid := String(claims.get("uid", ""))
	if not _uid_to_seat.has(uid):
		_send(peer_id, Protocol.make(Protocol.COMMAND_REJECTED, {"reason": "join_seat"}))
		return
	var idx: int = _uid_to_seat[uid]

	# Riaggancio: se un altro peer teneva questo posto, lo si stacca.
	if _seat_peer.has(idx):
		_peer_seat.erase(_seat_peer[idx])
	_peer_seat[peer_id] = idx
	_seat_peer[idx] = peer_id

	# BotBrain di rimpiazzo (disconnessione) rimosso; i bot veri restano.
	if _disconnect_seats.has(idx):
		_brains.erase(idx)
		_disconnect_seats.erase(idx)

	_send(peer_id, _match_state_msg(idx))
	_send(peer_id, Protocol.make(Protocol.ROUND_STARTED, {
		"stage": _state.stage,
		"round_index": _state.round_index,
		"prep_seconds": maxf(0.0, _prep_left),
	}))


func _on_surrender(peer_id: int) -> void:
	if not _peer_seat.has(peer_id):
		return
	# -> hp 0, eliminated; le classifiche seguono al resolve. Passa da MatchState
	# per prendere il timbro: chi si arrende ha perso la vita ADESSO.
	_state.apply_surrender(_peer_seat[peer_id])


# --------------------------------------------------------------------------
# Comandi — validazione a tre livelli (§M5)
# --------------------------------------------------------------------------

func _on_command(peer_id: int, msg: Dictionary) -> void:
	# 1. identita'.
	if not _peer_seat.has(peer_id):
		_send(peer_id, Protocol.make(Protocol.COMMAND_REJECTED, {"reason": "not_joined"}))
		return
	var idx: int = _peer_seat[peer_id]
	if msg.has("player_index") and int(msg["player_index"]) != idx:
		_send(peer_id, Protocol.make(Protocol.COMMAND_REJECTED, {"reason": "identity"}))
		return
	# 2. fase — core/ non conosce le fasi: e' il solo gate.
	if _phase != Phase.PREPARATION:
		_send(peer_id, Protocol.make(Protocol.COMMAND_REJECTED, {"reason": "phase"}))
		return
	# 2b. vita — un posto eliminato non compra e non aggiorna. can_buy/can_reroll
	#     lo rifiuterebbero comunque (core/player.gd), ma un motivo esplicito da'
	#     al client un messaggio sensato invece di un generico "mossa non
	#     consentita". Conta davvero: il pool e' condiviso.
	if not _state.players[idx].is_alive():
		_send(peer_id, Protocol.make(Protocol.COMMAND_REJECTED, {"reason": "eliminated"}))
		return
	# 3. regole — delegate ai metodi che gia' esistono in core/. Nessuna logica
	#    di gioco duplicata qui.
	var p: Player = _state.players[idx]
	var ok := false
	match Protocol.message_type(msg):
		Protocol.CMD_BUY:
			var slot := int(msg.get("slot", -1))
			ok = p.can_buy(slot) and p.buy(slot) != null
		Protocol.CMD_SELL:
			ok = p.sell_by_uid(int(msg.get("uid", -1)))
		Protocol.CMD_REROLL:
			ok = p.can_reroll() and p.reroll()
		Protocol.CMD_BUY_XP:
			ok = p.buy_xp()
		Protocol.CMD_MOVE_BOARD:
			ok = p.move_to_board_by_uid(int(msg.get("uid", -1)), msg.get("cell", Vector2i.ZERO))
		Protocol.CMD_MOVE_BENCH:
			ok = p.move_to_bench_by_uid(int(msg.get("uid", -1)), int(msg.get("slot", -1)))

	if not ok:
		_send(peer_id, Protocol.make(Protocol.COMMAND_REJECTED, {"reason": "rules"}))
		return
	_broadcast_state()  # il tavolo e' pubblico: ogni peer riceve la sua vista filtrata


func _on_ready(peer_id: int) -> void:
	if not _peer_seat.has(peer_id):
		return
	if _phase != Phase.PREPARATION:
		return
	_ready[_peer_seat[peer_id]] = true


func _on_spectate(peer_id: int, msg: Dictionary) -> void:
	# Stesso gate d'identita' di _on_command, che qui mancava: i log di
	# combattimento sono pubblici (tavolo, niente shop/oro), ma un peer che non
	# e' entrato nel match non deve poter interrogare il worker.
	if not _peer_seat.has(peer_id):
		_send(peer_id, Protocol.make(Protocol.COMMAND_REJECTED, {"reason": "not_joined"}))
		return
	var target := int(msg.get("player_index", -1))
	for row in _last_results:
		if row.get("combat", {}).is_empty():
			continue  # round a vuoto: nessuna battaglia da rivedere
		var p = row.get("player")
		var opp = row.get("opponent")
		var team := -1
		var opp_hero := ""
		if p != null and p.index == target:
			team = int(row.get("team", 0))
			opp_hero = opp.hero_id if opp != null else ""
		elif bool(row.get("ghost", false)) and opp != null and opp.index == target:
			# Endpoint eliminato di un matchup fantasma: stessa battaglia, lato opposto.
			team = 1 - int(row.get("team", 0))
			opp_hero = p.hero_id if p != null else ""
		else:
			continue
		var fields := {
			"player_index": target,
			"team": team,
			"opponent_hero_id": opp_hero,
		}
		_merge_combat(fields, row.get("combat", {}))
		_send(peer_id, Protocol.make(Protocol.SPECTATE_DATA, fields))
		return


# --------------------------------------------------------------------------
# Ciclo dei round
# --------------------------------------------------------------------------

func _open_preparation(first: bool) -> void:
	_phase = Phase.PREPARATION
	_ready.clear()
	_prep_left = _state.preparation_seconds()
	var msg := Protocol.make(Protocol.ROUND_STARTED, {
		"stage": _state.stage,
		"round_index": _state.round_index,
		"prep_seconds": _prep_left,
	})
	# Lo snapshot PRIMA di ROUND_STARTED: start_round() ha appena rigenerato i
	# negozi, e il client ridisegna la schermata di preparazione gia' su
	# ROUND_STARTED. Nell'ordine inverso si vedeva il negozio del round passato
	# finche' non arrivava il MATCH_STATE. Stesso ordine di _on_join().
	for idx in _seat_peer:
		_send(_seat_peer[idx], _match_state_msg(idx))
		_send(_seat_peer[idx], msg)


## Chi "cancella" il timer di preparazione: gli umani collegati ancora vivi. Gli
## eliminati non hanno un PRONTO (schermata spettatore) e non devono bloccare il
## round: se restano a guardare, il timer scorre comunque per conto suo.
func _all_live_humans_ready() -> bool:
	var gating: Array = []
	for s in _slots:
		if String(s.get("kind", "")) != "human":
			continue
		var idx := int(s.get("index", 0))
		if _seat_peer.has(idx) and _state.players[idx].is_alive():
			gating.append(idx)
	if gating.is_empty():
		return false
	for idx in gating:
		if not _ready.get(idx, false):
			return false
	return true


func _resolve_round() -> void:
	# I bot (e gli umani caduti) giocano la preparazione prima della risoluzione.
	for idx in _brains:
		_brains[idx].play_preparation(_state.stage)

	_last_results = _state.resolve_round()
	_phase = Phase.COMBAT

	var max_dur := 0.0
	for row in _last_results:
		max_dur = maxf(max_dur, float(row.get("combat", {}).get("duration", 0.0)))
	_combat_wait = max_dur + PACING_MARGIN

	# Invio mirato: ogni peer riceve SOLO il proprio log.
	for row in _last_results:
		var p: Player = row.get("player")
		if p == null or not _seat_peer.has(p.index):
			continue
		var peer: int = _seat_peer[p.index]
		var opp: Player = row.get("opponent")
		var fields := {
			"team": int(row.get("team", 0)),
			"opponent_hero_id": opp.hero_id if opp != null else "",
		}
		_merge_combat(fields, row.get("combat", {}))
		_send(peer, Protocol.make(Protocol.COMBAT, fields))

	var results_public := _public_results()
	for idx in _seat_peer:
		_send(_seat_peer[idx], Protocol.make(Protocol.ROUND_CONCLUDED, {"results": results_public}))
		_send(_seat_peer[idx], _match_state_msg(idx))

	if _state.phase == MatchState.Phase.FINISHED:
		_pending_finish = true


func _finish_match() -> void:
	_finished = true
	_phase = Phase.FINISHED
	var standings := _standings_data()
	for idx in _seat_peer:
		_send(_seat_peer[idx], Protocol.make(Protocol.MATCH_FINISHED, {"standings": standings}))
	StatsWriter.write_match(_stats_owner, match_id, seed_value, ranked, standings)


# --------------------------------------------------------------------------
# Serializzazione in uscita
# --------------------------------------------------------------------------

func _match_state_msg(for_index: int) -> Dictionary:
	# Invariante 3: mai lo stato privato altrui — sempre to_dict(for_index).
	return Protocol.make(Protocol.MATCH_STATE, {"state": _state.to_dict(for_index), "for_index": for_index})


func _broadcast_state() -> void:
	for idx in _seat_peer:
		_send(_seat_peer[idx], _match_state_msg(idx))


## Inserisce `combat` nei campi del messaggio, comprimendolo ZSTD se supera la
## soglia (Appendice A / C). Flag `zstd: true` + `combat_size` per il client.
func _merge_combat(fields: Dictionary, combat: Dictionary) -> void:
	var raw := var_to_bytes(combat)
	if raw.size() <= COMBAT_COMPRESS_THRESHOLD:
		fields["combat"] = combat
		return
	fields["zstd"] = true
	fields["combat_size"] = raw.size()
	fields["combat"] = raw.compress(FileAccess.COMPRESSION_ZSTD)


func _public_results() -> Array:
	var out: Array = []
	for row in _last_results:
		var p: Player = row.get("player")
		var opp: Player = row.get("opponent")
		out.append({
			"player_index": p.index if p != null else -1,
			"opponent_index": opp.index if opp != null else -1,
			"won": bool(row.get("won", false)),
			"damage": int(row.get("damage", 0)),
			"damage_dealt": int(row.get("damage_dealt", 0)),
			"ghost": bool(row.get("ghost", false)),
		})
	return out


func _standings_data() -> Array:
	var out: Array = []
	var uid_by_seat := {}
	for s in _slots:
		uid_by_seat[int(s.get("index", 0))] = String(s.get("uid", ""))
	for p in _state.standings():
		out.append({
			"player_index": p.index,
			"uid": uid_by_seat.get(p.index, ""),
			"placement": p.placement,
			"hp": p.hp,
			"hero_id": p.hero_id,
			"display_name": p.display_name,
			"is_bot": p.is_bot,
			"last_damage_stamp": p.last_damage_stamp,
		})
	return out


func _send(peer_id: int, msg: Dictionary) -> void:
	_outbox.append({"peers": [peer_id], "msg": msg})
