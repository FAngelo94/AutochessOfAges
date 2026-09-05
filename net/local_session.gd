class_name LocalSession
extends MatchSession

## Sessione single-player: possiede un vero MatchState, applica i comandi in
## locale e pilota i BotBrain. Comportamento identico a quello che ui/main.gd
## aveva in linea prima del refactor M3 — l'albero RNG dei bot compreso.

var _state: MatchState
var _brains: Array[BotBrain] = []
## Telemetria di bilanciamento della partita in corso (core/unit_telemetry.gd).
## Sola lettura sullo stato: non tocca l'RNG, la partita e' identica con o
## senza. La sfrutta ui/main.gd a fine partita per scrivere user://telemetry.jsonl.
var _telemetry := UnitTelemetry.new()


func begin(match_seed: int = 0, hero_id: String = "") -> void:
	_state = MatchState.new(match_seed, 1)
	_state.human_player().hero_id = hero_id

	# Costruzione dei bot e del loro albero RNG: spostata qui da ui/main.gd
	# INVARIATA. Non cambiare `seed_value ^ 0x5EED` ne' il fork(p.index), o le
	# partite con lo stesso seed smettono di riprodursi.
	_brains.clear()
	var brain_rng := SimRNG.new(_state.seed_value ^ 0x5EED)
	for p in _state.players:
		if p.is_bot:
			_brains.append(BotBrain.new(p, brain_rng.fork(p.index)))

	_telemetry.begin_match()
	_state.round_resolved.connect(_telemetry.on_round_resolved)

	_state.start_round()
	round_started.emit(_state.stage, _state.round_index)


func state() -> MatchState:
	return _state


func local_index() -> int:
	return _state.human_player().index


func request_buy(slot: int) -> void:
	_human().buy(slot)
	state_changed.emit()


func request_sell(uid: int) -> void:
	_human().sell_by_uid(uid)
	state_changed.emit()


func request_reroll() -> void:
	if not _human().reroll():
		command_rejected.emit("reroll")
	state_changed.emit()


func request_buy_xp() -> void:
	if not _human().buy_xp():
		command_rejected.emit("buy_xp")
	state_changed.emit()


func request_move_to_board(uid: int, cell: Vector2i) -> void:
	if not _human().move_to_board_by_uid(uid, cell):
		command_rejected.emit("board_full")
	state_changed.emit()


func request_move_to_bench(uid: int, slot: int) -> void:
	_human().move_to_bench_by_uid(uid, slot)
	state_changed.emit()


## Fine preparazione: i bot giocano il loro turno, poi si risolve il round e —
## se la partita continua — si apre subito il successivo. La UI ascolta
## round_concluded per l'eventuale replay e state_changed per il refresh.
func request_ready() -> void:
	for brain in _brains:
		brain.play_preparation(_state.stage)

	var results := _state.resolve_round()
	round_concluded.emit(results)

	if _state.phase == MatchState.Phase.FINISHED:
		_telemetry.on_match_finished(_state)
		match_finished.emit(_state.standings())
	else:
		_state.start_round()
		round_started.emit(_state.stage, _state.round_index)

	state_changed.emit()


## Telemetria della partita, per chi la vuole salvare (app/match_log.gd).
func telemetry() -> UnitTelemetry:
	return _telemetry


func can_spectate(player_index: int) -> bool:
	return not _spectate_row_for(player_index).is_empty()


func request_spectate(player_index: int) -> void:
	var found := _spectate_row_for(player_index)
	if found.is_empty():
		return
	spectate_ready.emit(player_index, found["combat"], int(found["team"]),
		String(found["opponent_hero_id"]))


## Individua la battaglia rivedibile per `idx`, sia come endpoint vivo
## (row["player"]) sia come endpoint eliminato di un matchup fantasma
## (row["opponent"], lato invertito). Ritorna {} se non c'è nulla da mostrare:
## round a vuoto, prima battaglia non ancora avvenuta, giocatore non coinvolto.
func _spectate_row_for(idx: int) -> Dictionary:
	for row in _state.last_results():
		if row.get("combat", {}).is_empty():
			continue
		var p: Player = row.get("player")
		var opp: Player = row.get("opponent")
		if p != null and p.index == idx:
			return {
				"combat": row["combat"],
				"team": int(row.get("team", 0)),
				"opponent_hero_id": opp.hero_id if opp != null else "",
			}
		if bool(row.get("ghost", false)) and opp != null and opp.index == idx:
			return {
				"combat": row["combat"],
				"team": 1 - int(row.get("team", 0)),
				"opponent_hero_id": p.hero_id if p != null else "",
			}
	return {}


func leave() -> void:
	pass


func _human() -> Player:
	return _state.human_player()
