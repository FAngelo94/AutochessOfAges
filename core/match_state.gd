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

## Quanti round guardare indietro per evitare di riproporre lo stesso avversario.
## Non è in balance.json di proposito: è una regola di accoppiamento, non un
## numero da bilanciare, e balance.json ha modifiche non committate in corso.
const REMATCH_AVOID_WINDOW := 2

var players: Array[Player] = []
var pool: UnitPool
var phase: int = Phase.PREPARATION
var stage: int = 1
var round_index: int = 1
var seed_value: int

var _rng: SimRNG
var _last_results: Array[Dictionary] = []
var _next_placement: int

## Orologio logico dei danni: cresce di uno a ogni colpo alla vita, per tutta la
## partita. Non consuma SimRNG e non guarda l'orologio di sistema — serve solo a
## ordinare due perdite di vita fra loro.
##
## NON viene serializzato di proposito: il client non simula mai e quindi non
## assegna timbri, riceve solo i `last_damage_stamp` già decisi qui. Se un
## giorno il client togliesse vita per conto suo, i timbri si sovrapporrebbero.
var _damage_clock: int = 0

## player.index -> Array[int] degli avversari degli ultimi REMATCH_AVOID_WINDOW
## round (il più recente in coda). Solo lato server: il client non accoppia.
var _recent_opponents: Dictionary = {}


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


# --------------------------------------------------------------------------
# Classifica dal vivo
# --------------------------------------------------------------------------

## Timbro successivo per una perdita di vita. Lo chiama chi infligge il danno —
## qui e server/match_runner.gd per la resa — mai Player.
func next_damage_stamp() -> int:
	_damage_clock += 1
	return _damage_clock


## Il criterio di classifica, unico in tutto il progetto: vita decrescente e, a
## parità di vita, davanti chi l'ha persa più tardi.
##
## Per gli eliminati (vita 0) la stessa regola diventa "chi è morto dopo sta
## davanti", che è esattamente l'ordine dei piazzamenti: un solo comparatore
## copre vivi e morti, la classifica in partita e quella finale.
static func ranks_before(a: Player, b: Player) -> bool:
	if a.hp != b.hp:
		return a.hp > b.hp
	if a.last_damage_stamp != b.last_damage_stamp:
		return a.last_damage_stamp > b.last_damage_stamp
	return a.index < b.index  # ultimo criterio: stabile e deterministico


## Tutti i giocatori dal primo all'ultimo secondo ranks_before().
func live_ranking() -> Array[Player]:
	var sorted: Array[Player] = players.duplicate()
	sorted.sort_custom(ranks_before)
	return sorted


## Posizione 1-based di un giocatore. Conta invece di cercare dentro
## live_ranking(): la HUD la chiede a ogni refresh e così non alloca un array.
func rank_of(player: Player) -> int:
	var position := 1
	for other in players:
		if other != player and ranks_before(other, player):
			position += 1
	return position


## Resa: azzera la vita del posto, con timbro — chi si arrende ha perso la vita
## adesso, quindi a parità di vita sta davanti a chi l'aveva persa prima.
func apply_surrender(player_index: int) -> void:
	if player_index < 0 or player_index >= players.size():
		return
	var p: Player = players[player_index]
	p.take_damage(p.hp, next_damage_stamp())


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
# Serializzazione (MULTIPLAYER_PLAN.md M0)
# --------------------------------------------------------------------------

## Snapshot completo dello stato, filtrato dal punto di vista di for_index:
## solo quel giocatore riceve shop/gold/xp/panchina, gli altri il solo tavolo.
func to_dict(for_index: int) -> Dictionary:
	var players_data: Array = []
	for i in players.size():
		players_data.append(players[i].to_dict(i == for_index))
	return {
		"phase": phase,
		"stage": stage,
		"round_index": round_index,
		"seed_value": seed_value,
		"players": players_data,
		"pool": pool.snapshot(),
	}


func apply_dict(d: Dictionary) -> void:
	phase = int(d.get("phase", phase))
	stage = int(d.get("stage", stage))
	round_index = int(d.get("round_index", round_index))
	seed_value = int(d.get("seed_value", seed_value))
	if d.has("pool"):
		pool.restore(d["pool"])
	var players_data: Array = d.get("players", [])
	for i in players_data.size():
		if i < players.size():
			players[i].apply_dict(players_data[i])


# --------------------------------------------------------------------------
# Ciclo di gioco
# --------------------------------------------------------------------------

func start_round() -> void:
	phase = Phase.PREPARATION
	for player in alive_players():
		player.refresh_shop()
	round_started.emit(stage, round_index)


## Accoppia i giocatori vivi. Si mescola in modo deterministico (shuffle_ex),
## poi si accoppia con una scelta greedy che evita gli avversari degli ultimi
## REMATCH_AVOID_WINDOW round finché è possibile — con 8 umani veri, ritrovarsi
## contro la stessa board 2-3 volte di fila è frustrante. Con un numero dispari
## di vivi, lo spaiato combatte contro un "fantasma": l'ultimo schieramento di
## un giocatore eliminato se ce n'è uno, altrimenti la copia di un vivo.
##
## Il consumo dello SimRNG è identico a prima (uno shuffle + al più un pick):
## cambia solo QUALE accoppiamento esce, non la posizione dello stream.
func build_matchups() -> Array[Dictionary]:
	var living := alive_players()
	var shuffled := living.duplicate()
	_rng.shuffle_ex(shuffled)

	var matchups: Array[Dictionary] = []
	var pending := shuffled.duplicate()
	while pending.size() >= 2:
		var a: Player = pending.pop_front()
		var seen: Array = _recent_opponents.get(a.index, [])
		var pick_at := -1
		for j in pending.size():
			if not seen.has(pending[j].index):
				pick_at = j
				break
		if pick_at == -1:
			pick_at = 0  # tutti già affrontati di recente: si accetta la rivincita
		var b: Player = pending[pick_at]
		pending.remove_at(pick_at)
		matchups.append({"a": a, "b": b, "ghost": false})
		_remember(a.index, b.index)
		_remember(b.index, a.index)

	if pending.size() == 1:
		var odd_one: Player = pending[0]
		# Il fantasma è, in ordine di preferenza: un giocatore eliminato (si
		# usa il suo ultimo schieramento, congelato al momento dell'uscita —
		# così l'esercito di chi è caduto resta in partita e nessun vivo si
		# vede "prestata" la squadra); in mancanza, la copia di un vivo.
		var candidates := players.filter(func(p: Player) -> bool:
			return not p.is_alive() and not p.board_units().is_empty())
		if candidates.is_empty():
			candidates = living.filter(func(p: Player) -> bool: return p != odd_one)
		if candidates.is_empty():
			matchups.append({"a": odd_one, "b": null, "ghost": true})
		else:
			var seen_odd: Array = _recent_opponents.get(odd_one.index, [])
			var fresh := candidates.filter(func(p: Player) -> bool: return not seen_odd.has(p.index))
			var ghost_opp: Player = _rng.pick(fresh if not fresh.is_empty() else candidates)
			matchups.append({"a": odd_one, "b": ghost_opp, "ghost": true})
			_remember(odd_one.index, ghost_opp.index)
	return matchups


## Registra un avversario nella cronologia di `who`, tenendo solo gli ultimi
## REMATCH_AVOID_WINDOW.
func _remember(who: int, opponent: int) -> void:
	var history: Array = _recent_opponents.get(who, [])
	history.append(opponent)
	while history.size() > REMATCH_AVOID_WINDOW:
		history.pop_front()
	_recent_opponents[who] = history


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
		return {"player": player_a, "opponent": null, "won": true, "damage": 0, "damage_dealt": 0, "ghost": true, "team": 0, "combat": {}}

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
		player_a.take_damage(damage_to_a, next_damage_stamp())
	elif a_won:
		damage_to_b = _compute_damage(sim, 0)
		if not matchup.get("ghost", false):
			player_b.take_damage(damage_to_b, next_damage_stamp())

	# Il risultato è registrato dal punto di vista del giocatore A; per B viene
	# aggiunto subito dopo, così ogni giocatore ha una riga sua.
	# "team" dice da che lato dell'arena era schierato questo giocatore: senza,
	# chi riproduce la battaglia non sa quale metà del campo è la propria.
	var result_a := {
		"player": player_a,
		"opponent": player_b,
		"won": a_won,
		"damage": damage_to_a,
		"damage_dealt": damage_to_b if a_won else 0,
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
			"damage_dealt": damage_to_a if b_won else 0,
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
	var fresh: Array[Player] = []
	for player in players:
		if player.eliminated and player.placement == 0:
			fresh.append(player)

	# I piazzamenti si assegnano a scendere da _next_placement, quindi si parte
	# dal PEGGIORE: fra due morti nello stesso round prende il numero più alto
	# chi ha incassato il colpo per primo. Prima l'ordine era quello dell'array
	# players, cioè l'indice del posto — arbitrario e senza rapporto col gioco.
	fresh.sort_custom(func(a: Player, b: Player) -> bool: return ranks_before(b, a))

	for player in fresh:
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
		# Non ancora piazzati (i vivi, a metà partita): stesso criterio della
		# classifica dal vivo, così le due viste non si contraddicono mai.
		return ranks_before(a, b))
	var result: Array[Player] = []
	for player in sorted:
		result.append(player)
	return result
