class_name MatchState
extends RefCounted

## Orchestratore della partita: turni, accoppiamenti, risoluzione dei
## combattimenti, danni ai giocatori, eliminazioni.
##
## Guida la simulazione a comandi espliciti (start_round / resolve_round), non
## a tempo: chi la usa decide quando far scattare la fase successiva. In locale
## è un timer della UI, online sarà il server.

signal round_started(stage: int, round_index: int)
signal round_resolved(results: Array)
signal player_eliminated(player: Player)
signal match_finished(standings: Array)

enum Phase { PREPARATION, COMBAT, FINISHED }

var players: Array[Player] = []
var pool: UnitPool
var phase: int = Phase.PREPARATION
var stage: int = 1
var round_index: int = 1
var seed_value: int

var _rng: SimRNG
var _last_results: Array[Dictionary] = []
var _next_placement: int


func _init(match_seed: int = 0, human_players: int = 1) -> void:
	seed_value = match_seed if match_seed != 0 else int(Time.get_unix_time_from_system() * 1000.0)
	_rng = SimRNG.new(seed_value)
	pool = UnitPool.new()

	var count := int(GameData.balance()["match"]["players"])
	_next_placement = count
	for i in count:
		# Ogni giocatore ha il proprio stream: gli acquisti di uno non
		# spostano le pescate degli altri, il che rende i test isolabili.
		var player := Player.new(pool, _rng.fork(i + 1))
		player.index = i
		player.is_bot = i >= human_players
		player.display_name = "Giocatore %d" % (i + 1) if not player.is_bot else "Bot %d" % i
		player.refresh_shop(false)
		players.append(player)


func human_player() -> Player:
	for player in players:
		if not player.is_bot:
			return player
	return players[0]


func alive_players() -> Array[Player]:
	var result: Array[Player] = []
	for player in players:
		if player.is_alive():
			result.append(player)
	return result


func round_label() -> String:
	return "%d-%d" % [stage, round_index]


func preparation_seconds() -> float:
	var rounds: Dictionary = GameData.balance()["rounds"]
	if stage == 1 and round_index == 1:
		return float(rounds["first_round_preparation_seconds"])
	return float(rounds["preparation_seconds"])


func last_results() -> Array[Dictionary]:
	return _last_results


# --------------------------------------------------------------------------
# Ciclo di gioco
# --------------------------------------------------------------------------

func start_round() -> void:
	phase = Phase.PREPARATION
	for player in alive_players():
		player.refresh_shop()
	round_started.emit(stage, round_index)


## Accoppia i giocatori vivi. Ogni giocatore incontra un avversario diverso
## finché possibile; con un numero dispari, uno combatte contro la copia della
## squadra di un altro (il "fantasma" del genere).
func build_matchups() -> Array[Dictionary]:
	var living := alive_players()
	var shuffled := living.duplicate()
	_rng.shuffle_ex(shuffled)

	var matchups: Array[Dictionary] = []
	var i := 0
	while i + 1 < shuffled.size():
		matchups.append({"a": shuffled[i], "b": shuffled[i + 1], "ghost": false})
		i += 2
	if shuffled.size() % 2 == 1:
		var odd_one: Player = shuffled[-1]
		var candidates := living.filter(func(p: Player) -> bool: return p != odd_one)
		if candidates.is_empty():
			matchups.append({"a": odd_one, "b": null, "ghost": true})
		else:
			matchups.append({"a": odd_one, "b": _rng.pick(candidates), "ghost": true})
	return matchups


## Risolve il round: combattimenti, danni, eliminazioni, reddito.
## Restituisce un risultato per giocatore, che la UI può mostrare o riprodurre.
func resolve_round() -> Array[Dictionary]:
	phase = Phase.COMBAT
	_last_results.clear()

	for matchup in build_matchups():
		_last_results.append(_resolve_matchup(matchup))

	_apply_eliminations()

	for player in alive_players():
		var won := false
		for result in _last_results:
			if result["player"] == player:
				won = result["won"]
				break
		player.grant_round_income(won)

	_advance_round()
	round_resolved.emit(_last_results)

	if alive_players().size() <= 1:
		_finish()

	return _last_results


func _resolve_matchup(matchup: Dictionary) -> Dictionary:
	var player_a: Player = matchup["a"]
	var player_b: Player = matchup["b"]

	if player_b == null:
		# Nessun avversario disponibile: round a vuoto, nessun danno.
		return {"player": player_a, "opponent": null, "won": true, "damage": 0, "ghost": true, "team": 0, "combat": {}}

	# Il seed del combattimento deriva da partita e round: rigiocare lo stesso
	# round con le stesse squadre dà lo stesso risultato.
	var combat_rng := SimRNG.new(seed_value ^ (stage * 7919 + round_index * 104729 + player_a.index * 31 + player_b.index))
	var sim := CombatSim.new(combat_rng)
	sim.setup(player_a.board_units(), player_b.board_units())
	var combat_result := sim.run()

	var a_won: bool = combat_result["outcome"] == CombatSim.Outcome.TEAM_A
	var b_won: bool = combat_result["outcome"] == CombatSim.Outcome.TEAM_B

	var damage_to_a := 0
	var damage_to_b := 0
	if b_won:
		damage_to_a = _compute_damage(sim, 1)
		player_a.take_damage(damage_to_a)
	elif a_won:
		damage_to_b = _compute_damage(sim, 0)
		if not matchup.get("ghost", false):
			player_b.take_damage(damage_to_b)

	# Il risultato è registrato dal punto di vista del giocatore A; per B viene
	# aggiunto subito dopo, così ogni giocatore ha una riga sua.
	# "team" dice da che lato dell'arena era schierato questo giocatore: senza,
	# chi riproduce la battaglia non sa quale metà del campo è la propria.
	var result_a := {
		"player": player_a,
		"opponent": player_b,
		"won": a_won,
		"damage": damage_to_a,
		"ghost": matchup.get("ghost", false),
		"team": 0,
		"combat": combat_result,
	}
	if not matchup.get("ghost", false):
		_last_results.append({
			"player": player_b,
			"opponent": player_a,
			"won": b_won,
			"damage": damage_to_b,
			"ghost": false,
			"team": 1,
			"combat": combat_result,
		})
	return result_a


## Danno alla vita: una base che cresce con lo stage, più un contributo per
## ogni unità nemica rimasta in piedi, pesato per stella.
func _compute_damage(sim: CombatSim, winning_team: int) -> int:
	var table: Dictionary = GameData.balance()["damage_to_player"]
	var stage_base: Array = table["stage_base"]
	var per_unit: Array = table["per_surviving_unit"]

	var damage := int(stage_base[clampi(stage - 1, 0, stage_base.size() - 1)])
	for unit in sim.alive_units(winning_team):
		damage += int(per_unit[clampi(unit.star - 1, 0, per_unit.size() - 1)])
	return damage


func _apply_eliminations() -> void:
	for player in players:
		if player.eliminated and player.placement == 0:
			player.placement = _next_placement
			_next_placement -= 1
			player_eliminated.emit(player)


func _advance_round() -> void:
	var rounds_per_stage := int(GameData.balance()["rounds"]["rounds_per_stage"])
	round_index += 1
	if round_index > rounds_per_stage:
		round_index = 1
		stage += 1


func _finish() -> void:
	phase = Phase.FINISHED
	for player in alive_players():
		player.placement = 1
	match_finished.emit(standings())


func standings() -> Array[Player]:
	var sorted := players.duplicate()
	sorted.sort_custom(func(a: Player, b: Player) -> bool:
		var pa := a.placement if a.placement > 0 else 0
		var pb := b.placement if b.placement > 0 else 0
		if pa != pb:
			return pa < pb
		return a.hp > b.hp)
	var result: Array[Player] = []
	for player in sorted:
		result.append(player)
	return result
