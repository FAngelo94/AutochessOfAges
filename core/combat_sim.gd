class_name CombatSim
extends RefCounted

## Risolutore di battaglia. Simulazione a passo fisso, completamente
## deterministica: stessi schieramenti + stesso seed = stessa battaglia, tick
## per tick. È il requisito che rende possibile il multiplayer autoritativo
## (il server simula, il client ripete) e i test di bilanciamento riproducibili.
##
## Il risolutore non conosce la UI: produce un log di eventi che la
## presentazione può riprodurre alla velocità che vuole.

enum Outcome { TEAM_A, TEAM_B, DRAW }

var arena_columns: int
var arena_rows: int
var tick_delta: float
var max_duration: float
var berserk_at: float
var berserk_scale: int

var units: Array[CombatUnit] = []
var events: Array[Dictionary] = []
## Orologio della SIMULAZIONE: è quello che leggono le unità per ricariche,
## effetti a tempo e stordimenti. Durante il berserk avanza più in fretta di
## `elapsed`, ed è esattamente questo scarto a rendere tutto tre volte più
## rapido senza toccare una sola riga della logica delle unità.
var time: float = 0.0
## Orologio del ROUND: 0 → max_duration, sempre a velocità reale. Decide la
## fine della battaglia e marca gli eventi, così la riproduzione dura quanto la
## barra che la accompagna e negli ultimi secondi si *vede* accelerare.
var elapsed: float = 0.0
var outcome: int = Outcome.DRAW

var _rng: SimRNG
## Fotografia dello schieramento a inizio battaglia. Insieme al log di eventi
## è tutto ciò che serve per riprodurre la battaglia: chi guarda non simula
## nulla, si limita a rigiocare quello che è già successo.
var _initial: Array[Dictionary] = []
## cella (Vector2i) -> uid dell'occupante vivo
var _occupancy: Dictionary = {}
var _by_uid: Dictionary = {}
var _deaths_by_team := {0: 0, 1: 0}
var _prune_accumulator := 0.0
var _berserk_announced := false


func _init(rng: SimRNG) -> void:
	_rng = rng
	var balance := GameData.balance()
	arena_columns = int(balance["match"]["board_columns"])
	arena_rows = int(balance["match"]["board_rows"]) * 2
	tick_delta = 1.0 / float(balance["combat"]["tick_rate"])
	max_duration = float(balance["combat"]["max_duration_seconds"])
	berserk_at = float(balance["combat"]["berserk_at_seconds"])
	berserk_scale = int(balance["combat"]["berserk_time_scale"])


# --------------------------------------------------------------------------
# Preparazione
# --------------------------------------------------------------------------

## Converte una cella della griglia del giocatore in una cella dell'arena.
## Il team 1 viene specchiato su entrambi gli assi, così le due formazioni si
## fronteggiano come le vede chi le ha disposte.
func board_cell_to_arena(cell: Vector2i, team: int) -> Vector2i:
	var half := arena_rows / 2
	if team == 0:
		return Vector2i(cell.x, (half - 1) - cell.y)
	return Vector2i((arena_columns - 1) - cell.x, half + cell.y)


func setup(team_a: Array[UnitInstance], team_b: Array[UnitInstance]) -> void:
	units.clear()
	events.clear()
	_occupancy.clear()
	_by_uid.clear()
	time = 0.0
	elapsed = 0.0
	_berserk_announced = false
	_deaths_by_team = {0: 0, 1: 0}

	_add_team(team_a, 0)
	_add_team(team_b, 1)

	# Ordine di aggiornamento stabile: è ciò che garantisce il determinismo,
	# perché l'esito di un pareggio di tempi dipende da chi agisce prima.
	units.sort_custom(func(a: CombatUnit, b: CombatUnit) -> bool:
		if a.team != b.team:
			return a.team < b.team
		return a.uid < b.uid)

	_initial.clear()
	for unit in units:
		_initial.append({
			"uid": unit.uid,
			"id": unit.def.id,
			"name": unit.def.display_name,
			"origin": unit.def.origin,
			"star": unit.star,
			"team": unit.team,
			"cell": unit.cell,
			"max_hp": unit.base_stat("max_hp"),
			"shield": unit.shield,
			"mana_max": unit.base_stat("mana_max"),
			"range": unit.effective_range(0.0),
		})


func _add_team(instances: Array[UnitInstance], team: int) -> void:
	var bonuses := TraitResolver.bonuses_by_uid(instances)
	for instance in instances:
		if not instance.is_on_board():
			continue
		var arena_cell := board_cell_to_arena(instance.cell, team)
		var unit := CombatUnit.from_instance(instance, team, arena_cell, bonuses.get(instance.uid, {}))
		# Gli uid dei due giocatori possono coincidere: li rendo univoci
		# all'interno della battaglia senza toccare lo stato persistente.
		unit.uid = instance.uid * 2 + team
		units.append(unit)
		_by_uid[unit.uid] = unit
		_occupancy[arena_cell] = unit.uid


# --------------------------------------------------------------------------
# Esecuzione
# --------------------------------------------------------------------------

## Esegue l'intera battaglia e restituisce il riepilogo.
func run() -> Dictionary:
	while not _is_finished():
		step()
	return result()


## Un passo del ROUND. Normalmente è anche un passo di simulazione; dopo
## `berserk_at` ne esegue `berserk_scale` di fila nello stesso intervallo di
## `elapsed`, ed è così che "tutto va a tripla velocità": attacchi, movimento,
## ricariche, veleni e stordimenti insieme, perché è il tempo stesso a scorrere
## più in fretta.
##
## I sotto-passi mantengono la durata di `tick_delta`: triplicare direttamente
## il passo avrebbe reso la simulazione più grossolana proprio nei secondi
## decisivi (un'unità avrebbe attraversato due terzi di cella per tick),
## cambiando gli esiti invece di limitarsi ad accelerarli.
func step() -> void:
	var substeps := berserk_scale if elapsed >= berserk_at else 1
	# `elapsed` si divide fra i sotto-passi: gli eventi restano distinguibili
	# nel tempo e la riproduzione non li ammucchia tutti sullo stesso istante.
	var slice := tick_delta / float(substeps)

	if substeps > 1 and not _berserk_announced:
		_berserk_announced = true
		_log("berserk", {"scale": berserk_scale})

	for _i in substeps:
		elapsed += slice
		time += tick_delta
		_advance()


func _advance() -> void:
	for unit in units:
		if unit.is_alive():
			_update_unit(unit)

	# Ripulisce i modificatori scaduti una volta al secondo: tenerli non
	# cambia il risultato, ma gli array crescerebbero per tutta la battaglia.
	_prune_accumulator += tick_delta
	if _prune_accumulator >= 1.0:
		_prune_accumulator = 0.0
		for unit in units:
			unit.prune(time)


func _is_finished() -> bool:
	# Scaduto il tempo del round è pareggio, punto: nessun confronto di salute
	# residua. Se due squadre non riescono a chiudere nemmeno con il berserk,
	# nessuna delle due ha vinto davvero, e `match_state` applica il danno solo
	# a chi ha un vincitore — quindi non ne esce ferito nessuno.
	if elapsed >= max_duration:
		outcome = Outcome.DRAW
		return true
	var alive_a := alive_count(0)
	var alive_b := alive_count(1)
	if alive_a == 0 and alive_b == 0:
		outcome = Outcome.DRAW
		return true
	if alive_a == 0:
		outcome = Outcome.TEAM_B
		return true
	if alive_b == 0:
		outcome = Outcome.TEAM_A
		return true
	return false


func alive_count(team: int) -> int:
	var count := 0
	for unit in units:
		if unit.team == team and unit.is_alive():
			count += 1
	return count


func alive_units(team: int) -> Array[CombatUnit]:
	var result: Array[CombatUnit] = []
	for unit in units:
		if unit.team == team and unit.is_alive():
			result.append(unit)
	return result


func result() -> Dictionary:
	return {
		"outcome": outcome,
		# Durata del ROUND, non della simulazione: è la lunghezza del replay e
		# la scala della barra che lo accompagna.
		"duration": elapsed,
		"berserk_at": berserk_at,
		"survivors_a": _survivor_summary(0),
		"survivors_b": _survivor_summary(1),
		"initial": _initial,
		"columns": arena_columns,
		"rows": arena_rows,
		"events": events,
	}


func _survivor_summary(team: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for unit in alive_units(team):
		result.append({
			"id": unit.def.id,
			"name": unit.def.display_name,
			"star": unit.star,
			"hp": unit.hp,
			"max_hp": unit.base_stat("max_hp"),
		})
	return result


# --------------------------------------------------------------------------
# Ciclo della singola unità
# --------------------------------------------------------------------------

func _update_unit(unit: CombatUnit) -> void:
	_apply_periodic_effects(unit)
	if not unit.is_alive():
		_kill(unit)
		return

	if unit.is_stunned():
		unit.stun_remaining -= tick_delta
		return

	unit.attack_cooldown = maxf(0.0, unit.attack_cooldown - tick_delta)
	unit.move_cooldown = maxf(0.0, unit.move_cooldown - tick_delta)

	if unit.is_ability_ready():
		_cast_ability(unit)
		if not unit.is_alive():
			_kill(unit)
			return

	var target := _acquire_target(unit)
	if target == null:
		unit.state = CombatUnit.State.IDLE
		return

	if _distance(unit.cell, target.cell) <= unit.effective_range(time):
		unit.state = CombatUnit.State.ATTACKING
		if unit.attack_cooldown <= 0.0:
			_perform_attack(unit, target)
			unit.attack_cooldown = 1.0 / unit.effective_attack_speed(time)
	else:
		unit.state = CombatUnit.State.MOVING
		if unit.move_cooldown <= 0.0:
			if _step_towards(unit, target):
				unit.move_cooldown = unit.move_interval(time)


## Intervallo con cui gli effetti continui finiscono nel log.
const PERIODIC_LOG_INTERVAL := 0.5

## Danno nel tempo e rigenerazione, applicati a ogni tick in proporzione.
func _apply_periodic_effects(unit: CombatUnit) -> void:
	var regen := unit.stat("regen_per_second", time)
	if regen > 0.0:
		unit.periodic_delta += unit.heal(regen * tick_delta, time)

	for dot in unit.active_dots(time):
		var raw := float(dot["dps"]) * tick_delta
		var mitigated := unit.mitigate(raw, int(dot["type"]), time)
		unit.periodic_delta -= unit.apply_damage(mitigated, time)
		var source: CombatUnit = _by_uid.get(int(dot["source"]))
		if source != null:
			source.record_damage_dealt(mitigated)
		if not unit.is_alive():
			_flush_periodic(unit)
			return

	unit.periodic_timer += tick_delta
	if unit.periodic_timer >= PERIODIC_LOG_INTERVAL:
		_flush_periodic(unit)


func _flush_periodic(unit: CombatUnit) -> void:
	unit.periodic_timer = 0.0
	if is_zero_approx(unit.periodic_delta):
		return
	_log("periodic", {"uid": unit.uid, "delta": unit.periodic_delta, "hp": unit.hp})
	unit.periodic_delta = 0.0


# --------------------------------------------------------------------------
# Bersagli e movimento
# --------------------------------------------------------------------------

## Distanza sulla griglia esagonale: sei direzioni, tutte dello stesso costo.
## Non esiste piu' la diagonale che avvicinava di due caselle al prezzo di una,
## quindi le gittate espresse in celle valgono ora quello che dicono.
func _distance(a: Vector2i, b: Vector2i) -> int:
	return Hex.distance(a, b)


func _acquire_target(unit: CombatUnit) -> CombatUnit:
	var current: CombatUnit = _by_uid.get(unit.target_uid)
	if current != null and current.is_alive():
		return current
	var nearest := _find_nearest_enemy(unit)
	unit.target_uid = nearest.uid if nearest != null else -1
	return nearest


## Nemico più vicino. A parità di distanza vince l'uid più basso: qualunque
## criterio va bene purché sia sempre lo stesso.
func _find_nearest_enemy(unit: CombatUnit) -> CombatUnit:
	var best: CombatUnit = null
	var best_distance := 1 << 30
	for other in units:
		if other.team == unit.team or not other.is_alive():
			continue
		var distance := _distance(unit.cell, other.cell)
		if distance < best_distance or (distance == best_distance and best != null and other.uid < best.uid):
			best = other
			best_distance = distance
	return best


## Un passo verso il bersaglio, aggirando le unità con una ricerca in ampiezza
## sulle celle libere. Restituisce false se non esiste un percorso.
func _step_towards(unit: CombatUnit, target: CombatUnit) -> bool:
	var attack_range := unit.effective_range(time)
	var start := unit.cell

	var came_from := {start: start}
	var queue: Array[Vector2i] = [start]
	var head := 0

	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1

		if current != start and _distance(current, target.cell) <= attack_range:
			# Risale il percorso fino al primo passo da compiere.
			var step := current
			while came_from[step] != start:
				step = came_from[step]
			return _move_unit(unit, step)

		for neighbour in _neighbours(current):
			if came_from.has(neighbour):
				continue
			if _occupancy.has(neighbour):
				continue
			came_from[neighbour] = current
			queue.append(neighbour)

	return false


## Le sei celle adiacenti che cadono dentro l'arena. L'ordine lo fissa Hex e
## non deve mai cambiare: decide quale percorso, fra piu' percorsi di pari
## lunghezza, sceglie la ricerca in ampiezza.
func _neighbours(cell: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for next in Hex.neighbours(cell):
		if next.x >= 0 and next.x < arena_columns and next.y >= 0 and next.y < arena_rows:
			result.append(next)
	return result


func _move_unit(unit: CombatUnit, to_cell: Vector2i) -> bool:
	if _occupancy.has(to_cell):
		return false
	_occupancy.erase(unit.cell)
	var from := unit.cell
	unit.cell = to_cell
	_occupancy[to_cell] = unit.uid
	_log("move", {"uid": unit.uid, "from": from, "to": to_cell})
	return true


func unit_at(cell: Vector2i) -> CombatUnit:
	if not _occupancy.has(cell):
		return null
	return _by_uid.get(int(_occupancy[cell]))


# --------------------------------------------------------------------------
# Attacco base
# --------------------------------------------------------------------------

func _perform_attack(attacker: CombatUnit, target: CombatUnit) -> void:
	var damage := attacker.stat("attack_damage", time)

	var is_crit := _rng.chance(attacker.stat("crit_chance", time))
	if is_crit:
		damage *= attacker.stat("crit_damage", time)

	# Carica della cavalleria: solo al primo colpo della battaglia.
	if not attacker.has_attacked:
		damage += attacker.stat("charge_damage", time)
		attacker.has_attacked = true

	# Assedio: percentuale della salute massima del bersaglio.
	var max_hp_bonus := attacker.stat("max_hp_damage", time) * target.base_stat("max_hp")

	var dealt := _deal_damage(attacker, target, damage, CombatUnit.DAMAGE_PHYSICAL)
	if max_hp_bonus > 0.0:
		dealt += _deal_damage(attacker, target, max_hp_bonus, CombatUnit.DAMAGE_TRUE)

	# Berserker: parte del danno si riversa sui nemici adiacenti al bersaglio.
	var cleave := attacker.stat("cleave", time)
	if cleave > 0.0:
		for neighbour_cell in _neighbours(target.cell):
			var splash_target := unit_at(neighbour_cell)
			if splash_target != null and splash_target.team != attacker.team and splash_target.is_alive():
				_deal_damage(attacker, splash_target, damage * cleave, CombatUnit.DAMAGE_PHYSICAL)

	attacker.gain_mana(float(GameData.balance()["combat"]["mana_per_attack"]))

	var omnivamp := attacker.stat("omnivamp", time)
	if omnivamp > 0.0 and dealt > 0.0:
		attacker.heal(dealt * omnivamp, time)

	_log("attack", {
		"uid": attacker.uid,
		"target": target.uid,
		"damage": dealt,
		"crit": is_crit,
	})

	if not target.is_alive():
		_kill(target)


## Applica il danno mitigato e ne registra l'attribuzione. Restituisce il
## danno effettivamente inflitto alla salute.
func _deal_damage(source: CombatUnit, target: CombatUnit, amount: float, damage_type: int) -> float:
	if not target.is_alive() or amount <= 0.0:
		return 0.0
	var mitigated := target.mitigate(amount, damage_type, time)
	var dealt := target.apply_damage(mitigated, time)
	source.record_damage_dealt(mitigated)

	# Il log riporta la salute RISULTANTE, non solo il danno: chi riproduce la
	# battaglia non deve rifare i conti di mitigazione e scudi.
	_log("damage", {
		"uid": target.uid,
		"source": source.uid,
		"amount": mitigated,
		"kind": damage_type,
		"hp": target.hp,
		"shield": target.shield,
	})

	if not target.is_alive():
		_kill(target)
	return dealt


func _kill(unit: CombatUnit) -> void:
	if _occupancy.get(unit.cell) != unit.uid:
		return  # già rimosso
	_occupancy.erase(unit.cell)
	unit.state = CombatUnit.State.DEAD
	_deaths_by_team[unit.team] = int(_deaths_by_team[unit.team]) + 1
	_log("death", {"uid": unit.uid})

	# Furia gallica: la morte di un alleato rafforza chi resta in piedi.
	for ally in units:
		if ally.team == unit.team and ally.is_alive() and ally.base_stat("rage_per_death") > 0.0:
			ally.rage_stacks += 1


# --------------------------------------------------------------------------
# Abilità
# --------------------------------------------------------------------------

func _cast_ability(caster: CombatUnit) -> void:
	var star := caster.star
	var def := caster.def
	var ability_type := def.ability_type()
	var duration := float(def.ability_param("duration", star, 0.0))
	var until := time + duration

	_log("cast", {"uid": caster.uid, "ability": ability_type, "name": def.ability.get("name", "")})
	caster.consume_mana()

	match ability_type:
		"shield_self":
			caster.add_shield(float(def.ability_param("amount", star)))
			var reduction := float(def.ability_param("damage_reduction", star, 0.0))
			if reduction > 0.0:
				caster.add_mod("damage_reduction", reduction, until)
			# La riflessione è modellata come danno immediato al bersaglio
			# corrente: tenerla passiva richiederebbe stato aggiuntivo per un
			# effetto marginale.
			var reflect := float(def.ability_param("reflect", star, 0.0))
			if reflect > 0.0:
				var current: CombatUnit = _by_uid.get(caster.target_uid)
				if current != null and current.is_alive():
					_deal_damage(caster, current, caster.base_stat("attack_damage") * reflect, CombatUnit.DAMAGE_MAGIC)

		"buff_self":
			caster.add_mod("attack_speed_percent", float(def.ability_param("attack_speed_bonus", star)), until)

		"damage_splash":
			var centre := caster.cell
			var target_mode := String(def.ability_param("target", star, "current"))
			if target_mode != "self":
				var focus := _select_target(caster, target_mode)
				if focus == null:
					return
				centre = focus.cell
			_damage_area(caster, centre, int(def.ability_param("radius", star, 1)), float(def.ability_param("damage", star)))

		"damage_line":
			var focus := _select_target(caster, String(def.ability_param("target", star, "current")))
			if focus == null:
				return
			_damage_line(caster, focus.cell, float(def.ability_param("damage", star)))

		"damage_nearest":
			var count := int(def.ability_param("targets", star, 1))
			var damage := float(def.ability_param("damage", star))
			var slow := float(def.ability_param("attack_speed_slow", star, 0.0))
			for victim in _nearest_enemies(caster, count):
				_deal_damage(caster, victim, damage, CombatUnit.DAMAGE_MAGIC)
				if slow > 0.0 and victim.is_alive():
					victim.add_mod("attack_speed_percent", -slow, until)

		"damage_over_time":
			var focus := _select_target(caster, String(def.ability_param("target", star, "current")))
			if focus == null:
				return
			var total := float(def.ability_param("damage", star))
			focus.add_dot(total / maxf(0.1, duration), until, CombatUnit.DAMAGE_MAGIC, caster.uid)
			var heal_reduction := float(def.ability_param("heal_reduction", star, 0.0))
			if heal_reduction > 0.0:
				focus.add_mod("heal_power", -heal_reduction, until)

		"damage_execute":
			var focus := _select_target(caster, String(def.ability_param("target", star, "current")))
			if focus == null:
				return
			var damage := float(def.ability_param("damage", star))
			damage += focus.missing_hp() * float(def.ability_param("missing_hp_scaling", star, 0.0))
			damage += focus.base_stat("max_hp") * float(def.ability_param("max_hp_scaling", star, 0.0))
			_deal_damage(caster, focus, damage, CombatUnit.DAMAGE_MAGIC)

		"stun_target":
			var focus := _select_target(caster, String(def.ability_param("target", star, "current")))
			if focus == null:
				return
			_deal_damage(caster, focus, float(def.ability_param("damage", star)), CombatUnit.DAMAGE_MAGIC)
			if focus.is_alive():
				focus.stun_remaining = maxf(focus.stun_remaining, float(def.ability_param("duration", star, 1.0)))
				_log("stun", {"uid": focus.uid, "by": caster.uid})

		"heal_lowest_ally":
			var ally := _lowest_hp_ally(caster)
			if ally == null:
				return
			var healed := ally.heal(float(def.ability_param("amount", star)), time)
			var shield_amount := float(def.ability_param("shield", star, 0.0))
			if shield_amount > 0.0:
				ally.add_shield(shield_amount)
			var regen := float(def.ability_param("regen", star, 0.0))
			if regen > 0.0:
				ally.add_mod("regen_per_second", regen, until)
			_log("heal", {
				"uid": ally.uid,
				"source": caster.uid,
				"amount": healed,
				"hp": ally.hp,
				"shield": ally.shield,
			})

		"shield_allies":
			var amount := float(def.ability_param("amount", star))
			var armor_bonus := float(def.ability_param("armor", star, 0.0))
			caster.add_shield(amount)
			if armor_bonus > 0.0:
				caster.add_mod("armor", armor_bonus, until)
			for ally in _nearest_allies(caster, int(def.ability_param("allies", star, 2))):
				ally.add_shield(amount)
				if armor_bonus > 0.0:
					ally.add_mod("armor", armor_bonus, until)

		"rally":
			_damage_area(caster, caster.cell, int(def.ability_param("radius", star, 1)), float(def.ability_param("damage", star)))
			var attack_speed_bonus := float(def.ability_param("attack_speed_bonus", star, 0.0))
			var omnivamp := float(def.ability_param("omnivamp", star, 0.0))
			var shield_amount := float(def.ability_param("shield", star, 0.0))
			var self_only := bool(def.ability_param("self_only", star, false))
			var beneficiaries: Array[CombatUnit] = [caster] if self_only else alive_units(caster.team)
			for ally in beneficiaries:
				if attack_speed_bonus > 0.0:
					ally.add_mod("attack_speed_percent", attack_speed_bonus, until)
				if omnivamp > 0.0:
					ally.add_mod("omnivamp", omnivamp, until)
				if shield_amount > 0.0 and _distance(ally.cell, caster.cell) <= 2:
					ally.add_shield(shield_amount)

		_:
			push_warning("CombatSim: tipo di abilità non gestito '%s' (%s)" % [ability_type, def.id])


func _damage_area(caster: CombatUnit, centre: Vector2i, radius: int, damage: float) -> void:
	for unit in units:
		if unit.team == caster.team or not unit.is_alive():
			continue
		if _distance(unit.cell, centre) <= radius:
			_deal_damage(caster, unit, damage, CombatUnit.DAMAGE_MAGIC)


## Colpisce tutti i nemici sulla retta che va dal lanciatore al bersaglio,
## proseguendo oltre fino al bordo dell'arena.
func _damage_line(caster: CombatUnit, towards: Vector2i, damage: float) -> void:
	var delta := towards - caster.cell
	var step := Vector2i(signi(delta.x), signi(delta.y))
	if step == Vector2i.ZERO:
		return
	var cursor := caster.cell + step
	while cursor.x >= 0 and cursor.x < arena_columns and cursor.y >= 0 and cursor.y < arena_rows:
		var victim := unit_at(cursor)
		if victim != null and victim.team != caster.team and victim.is_alive():
			_deal_damage(caster, victim, damage, CombatUnit.DAMAGE_MAGIC)
		cursor += step


func _select_target(caster: CombatUnit, mode: String) -> CombatUnit:
	var enemies := alive_units(1 - caster.team)
	if enemies.is_empty():
		return null

	match mode:
		"current":
			var current: CombatUnit = _by_uid.get(caster.target_uid)
			if current != null and current.is_alive():
				return current
			return _find_nearest_enemy(caster)
		"farthest":
			var best: CombatUnit = enemies[0]
			for enemy in enemies:
				var distance := _distance(caster.cell, enemy.cell)
				var best_distance := _distance(caster.cell, best.cell)
				if distance > best_distance or (distance == best_distance and enemy.uid < best.uid):
					best = enemy
			return best
		"lowest_hp":
			var best: CombatUnit = enemies[0]
			for enemy in enemies:
				if enemy.hp < best.hp or (enemy.hp == best.hp and enemy.uid < best.uid):
					best = enemy
			return best
		"highest_hp":
			var best: CombatUnit = enemies[0]
			for enemy in enemies:
				if enemy.hp > best.hp or (enemy.hp == best.hp and enemy.uid < best.uid):
					best = enemy
			return best
		_:
			return _find_nearest_enemy(caster)


func _nearest_enemies(caster: CombatUnit, count: int) -> Array[CombatUnit]:
	var enemies := alive_units(1 - caster.team)
	enemies.sort_custom(func(a: CombatUnit, b: CombatUnit) -> bool:
		var da := _distance(caster.cell, a.cell)
		var db := _distance(caster.cell, b.cell)
		if da != db:
			return da < db
		return a.uid < b.uid)
	return enemies.slice(0, count)


func _nearest_allies(caster: CombatUnit, count: int) -> Array[CombatUnit]:
	var allies: Array[CombatUnit] = []
	for unit in alive_units(caster.team):
		if unit.uid != caster.uid:
			allies.append(unit)
	allies.sort_custom(func(a: CombatUnit, b: CombatUnit) -> bool:
		var da := _distance(caster.cell, a.cell)
		var db := _distance(caster.cell, b.cell)
		if da != db:
			return da < db
		return a.uid < b.uid)
	return allies.slice(0, count)


func _lowest_hp_ally(caster: CombatUnit) -> CombatUnit:
	var best: CombatUnit = null
	for unit in alive_units(caster.team):
		if best == null or unit.hp_ratio() < best.hp_ratio() or (unit.hp_ratio() == best.hp_ratio() and unit.uid < best.uid):
			best = unit
	return best


func _log(type: String, data: Dictionary) -> void:
	# Marcati sull'orologio del round: durante il berserk gli eventi si
	# addensano nello stesso secondo di riproduzione, ed è proprio l'effetto
	# voluto — chi guarda vede la battaglia accelerare.
	data["t"] = elapsed
	data["type"] = type
	events.append(data)
