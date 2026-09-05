class_name UnitTelemetry
extends RefCounted

## Telemetria di bilanciamento: quanto un'unità viene schierata, quanto vince,
## quanto danno fa. Puro come il resto di core/ — nessun Node, nessuna rete,
## nessuna UI — e di sola lettura sullo stato: non tocca mai l'RNG, quindi
## agganciarlo a una partita non ne cambia il risultato (il test di determinismo
## resta valido).
##
## Nasce estraendo l'accumulatore che viveva dentro tools/balance_sim.gd, così
## le stesse statistiche si raccolgono da tre sorgenti con lo stesso codice:
##   - partite simulate di soli bot (tools/balance_sim.gd)
##   - partite locali contro il computer (net/local_session.gd -> user://)
##   - partite online autoritative (server/match_runner.gd -> Postgres)
##
## Due contabilità distinte, volutamente:
##
##   1. `units` / `traits` — aggregato globale, nella forma esatta del JSON che
##      tools/print_report.py sa già stampare. Conta le unità di *entrambe* le
##      squadre di ogni combattimento, una volta per riga di risultato: siccome
##      resolve_round() produce una riga per giocatore e le due righe di uno
##      stesso scontro condividono il dizionario `combat`, ogni unità di un
##      normale scontro finisce contata due volte. È indifferente ai winrate
##      (il fattore 2 è uniforme) ed è il comportamento storico del report: va
##      lasciato com'è, o i numeri non sono più confrontabili con quelli vecchi.
##
##   2. `_seats` — per giocatore e per unità, contato *una sola volta* per
##      round dalla formazione di quel giocatore. È questo che finisce nel DB
##      (match_rows), dove "in quanti round ho schierato questa unità" deve
##      essere un numero vero.

## Aggregato globale per unità: id -> dizionario di contatori.
var units: Dictionary = {}
## trait_id@soglia -> {trait, threshold, games, wins, draws}
var traits: Dictionary = {}

var total_rounds: int = 0
var draws: int = 0
var duration_sum: float = 0.0
var duration_n: int = 0
var level_sum: int = 0
var level_n: int = 0
var max_level_seen: int = 0
var matches: int = 0

## player_index -> {unit_id -> riga}. Azzerato a ogni begin_match().
var _seats: Dictionary = {}
## Round giocati nella partita corrente (total_rounds è il totale su tutte).
var _match_rounds: int = 0


func _init() -> void:
	GameData.ensure_loaded()
	for def in GameData.all_units():
		units[def.id] = {
			"id": def.id, "name": def.display_name, "origin": def.origin,
			"cost": def.cost,
			"rounds": 0, "wins": 0, "losses": 0, "round_draws": 0,
			"dmg_phys": 0.0, "dmg_magic": 0.0, "dmg_true": 0.0, "dmg_taken": 0.0,
			"healing": 0.0, "casts": 0, "attacks": 0, "crits": 0, "deaths": 0,
			"star_sum": 0,
			"fielded_end": 0, "placement_sum": 0, "placement_n": 0, "top4": 0,
		}


## Da chiamare all'inizio di ogni partita. L'aggregato globale prosegue tra una
## partita e l'altra (è il report cumulativo); solo la contabilità per posto
## viene azzerata.
func begin_match() -> void:
	_seats.clear()
	_match_rounds = 0
	matches += 1


## Numero di round giocati nella partita corrente.
func match_rounds() -> int:
	return _match_rounds


## Aggancio a MatchState.round_resolved. `results` è l'array di righe di
## resolve_round(): {player, opponent, won, ghost, team, combat}.
func on_round_resolved(results: Array) -> void:
	total_rounds += 1
	_match_rounds += 1

	# ---- contabilità per giocatore (una riga per giocatore, niente doppioni) --
	for r in results:
		var player: Player = r.get("player")
		if player == null:
			continue
		var combat: Dictionary = r.get("combat", {})
		var outcome := int(combat.get("outcome", -1)) if not combat.is_empty() else -1
		var drew := outcome == CombatSim.Outcome.DRAW
		var won := bool(r.get("won", false))
		var seat: Dictionary = _seats.get(player.index, {})
		for inst in player.board_units():
			var row: Dictionary = seat.get(inst.def.id, {
				"unit_id": inst.def.id, "final_star": 1, "fielded_end": false,
				"rounds_fielded": 0, "rounds_won": 0, "rounds_lost": 0, "rounds_drawn": 0,
			})
			row["rounds_fielded"] += 1
			row["final_star"] = maxi(int(row["final_star"]), inst.star)
			if combat.is_empty():
				pass          # round a vuoto: schierata, ma nessuno scontro da vincere
			elif drew:
				row["rounds_drawn"] += 1
			elif won:
				row["rounds_won"] += 1
			else:
				row["rounds_lost"] += 1
			seat[inst.def.id] = row
		_seats[player.index] = seat

	# ---- aggregato globale (forma storica del report) ------------------------
	for r in results:
		if r.get("ghost", false):
			continue
		var combat: Dictionary = r.get("combat", {})
		if combat.is_empty():
			continue
		var my_team := int(r["team"])
		var outcome := int(combat["outcome"])

		# sinergie: conteggio reale della formazione del giocatore
		var counts: Dictionary = TraitResolver.count_traits(r["player"].board_units())
		for trait_id in counts:
			var tier: Dictionary = GameData.active_tier(trait_id, int(counts[trait_id]))
			if tier.is_empty():
				continue
			var key := "%s@%d" % [trait_id, int(tier["count"])]
			var slot: Dictionary = traits.get(key, {
				"trait": trait_id, "threshold": int(tier["count"]),
				"games": 0, "wins": 0, "draws": 0,
			})
			slot["games"] += 1
			if outcome == CombatSim.Outcome.DRAW:
				slot["draws"] += 1
			elif (outcome == CombatSim.Outcome.TEAM_A) == (my_team == 0):
				slot["wins"] += 1
			traits[key] = slot

		# per unità: dalla formazione iniziale e dall'event log del combattimento
		var uid_to_id := {}
		for e in combat["initial"]:
			uid_to_id[e["uid"]] = e["id"]

		for e in combat["initial"]:
			var u: Dictionary = units[e["id"]]
			u["rounds"] += 1
			u["star_sum"] += int(e["star"])
			var drew := outcome == CombatSim.Outcome.DRAW
			if drew:
				u["round_draws"] += 1
			elif (outcome == CombatSim.Outcome.TEAM_A) == (int(e["team"]) == 0):
				u["wins"] += 1
			else:
				u["losses"] += 1

		duration_sum += float(combat["duration"])
		duration_n += 1
		if outcome == CombatSim.Outcome.DRAW:
			draws += 1

		for ev in combat["events"]:
			var type: String = ev["type"]
			match type:
				"damage":
					var src = ev.get("source")
					if src == null or not uid_to_id.has(src):
						continue
					var u: Dictionary = units[uid_to_id[src]]
					var amt := float(ev["amount"])
					match int(ev["kind"]):
						0: u["dmg_phys"] += amt
						1: u["dmg_magic"] += amt
						2: u["dmg_true"] += amt
					if uid_to_id.has(ev["uid"]):
						units[uid_to_id[ev["uid"]]]["dmg_taken"] += amt
				"heal":
					var src = ev.get("source")
					if src != null and uid_to_id.has(src):
						units[uid_to_id[src]]["healing"] += float(ev["amount"])
				"attack":
					if uid_to_id.has(ev["uid"]):
						var u: Dictionary = units[uid_to_id[ev["uid"]]]
						u["attacks"] += 1
						if ev.get("crit", false):
							u["crits"] += 1
				"cast":
					if uid_to_id.has(ev["uid"]):
						units[uid_to_id[ev["uid"]]]["casts"] += 1
				"death":
					if uid_to_id.has(ev["uid"]):
						units[uid_to_id[ev["uid"]]]["deaths"] += 1


## Da chiamare a partita conclusa: piazzamenti e formazione finale.
func on_match_finished(state: MatchState) -> void:
	var half := state.players.size() / 2
	for p in state.standings():
		level_sum += p.level
		level_n += 1
		max_level_seen = maxi(max_level_seen, p.level)
		var top4: bool = p.placement <= half
		var seat: Dictionary = _seats.get(p.index, {})
		for inst in p.board_units():
			var u: Dictionary = units[inst.def.id]
			u["fielded_end"] += 1
			u["placement_sum"] += p.placement
			u["placement_n"] += 1
			if top4:
				u["top4"] += 1
			if seat.has(inst.def.id):
				seat[inst.def.id]["fielded_end"] = true
				seat[inst.def.id]["final_star"] = maxi(
					int(seat[inst.def.id]["final_star"]), inst.star)
		for unit_id in seat:
			seat[unit_id]["placement"] = p.placement
		_seats[p.index] = seat


## Righe leggere per il DB: una per (giocatore umano, unità schierata almeno un
## round). `uid_by_index` mappa player_index -> profile_id; i posti assenti o con
## uid vuoto (i bot, che sul server non hanno profilo) non producono righe —
## stessa regola di StatsWriter._human_results().
func match_rows(uid_by_index: Dictionary) -> Array:
	var out: Array = []
	for index in _seats:
		var uid := String(uid_by_index.get(index, ""))
		if uid == "":
			continue
		for unit_id in _seats[index]:
			var row: Dictionary = _seats[index][unit_id].duplicate()
			row["profile_id"] = uid
			row["placement"] = int(row.get("placement", 0))
			out.append(row)
	return out


## Le stesse righe della partita corrente ma per tutti i posti, bot compresi:
## serve alla telemetria locale, dove non esistono profile_id.
func local_rows() -> Array:
	var out: Array = []
	for index in _seats:
		for unit_id in _seats[index]:
			var row: Dictionary = _seats[index][unit_id].duplicate()
			row["player_index"] = index
			out.append(row)
	return out


## Dump cumulativo nella forma del JSON di balance_sim, così print_report.py e
## merge_shards.py continuano a funzionare senza modifiche. `extra` sovrascrive
## le chiavi omonime (balance_sim ci mette il numero di partite richieste e il
## seed base).
func report_dict(extra: Dictionary = {}) -> Dictionary:
	var out := {
		"matches": matches, "base_seed": 0,
		"total_rounds": total_rounds,
		"round_draw_pct": pct(draws, duration_n),
		"avg_round_duration": duration_sum / maxf(duration_n, 1),
		"level_sum": level_sum, "level_n": level_n, "max_level_seen": max_level_seen,
		"units": units, "traits": traits,
	}
	for key in extra:
		out[key] = extra[key]
	return out


static func pct(a: float, b: float) -> float:
	return 0.0 if b == 0.0 else 100.0 * a / b
