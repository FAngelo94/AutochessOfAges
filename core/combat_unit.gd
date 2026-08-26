class_name CombatUnit
extends RefCounted

## Un'unità schierata in battaglia. Usa e getta: viene creata all'inizio del
## combattimento a partire da una UnitInstance e buttata via alla fine, così
## nessun danno subito può filtrare nello stato persistente della squadra.

enum State { IDLE, MOVING, ATTACKING, DEAD }

const DAMAGE_PHYSICAL := 0
const DAMAGE_MAGIC := 1
const DAMAGE_TRUE := 2

var uid: int
var def: UnitDef
var star: int
var team: int
var cell: Vector2i

## Statistiche finali dopo stella e tratti. Non cambiano durante la battaglia:
## le variazioni temporanee stanno in _mods.
var stats: Dictionary = {}

var hp: float
var shield: float = 0.0
var mana: float = 0.0
var state: int = State.IDLE
var target_uid: int = -1

var attack_cooldown: float = 0.0
var move_cooldown: float = 0.0
var stun_remaining: float = 0.0
var has_attacked := false

## Modificatori temporanei: {stat, add, until}. 'until' è il tempo di
## simulazione oltre il quale il modificatore non conta più.
var _mods: Array[Dictionary] = []
## Effetti a tempo sul bersaglio: {damage_per_second, until, source_uid, ...}
var _dots: Array[Dictionary] = []

## Bonus da furia gallica: cresce quando un alleato muore.
var rage_stacks: int = 0

## Accumulatori per il log degli effetti continui (veleno, rigenerazione).
## Registrarli a ogni tick significherebbe 30 eventi al secondo per unità: si
## accumulano e si emette un evento solo ogni tanto.
var periodic_delta: float = 0.0
var periodic_timer: float = 0.0

var _damage_dealt: float = 0.0
var _damage_taken: float = 0.0


static func from_instance(instance: UnitInstance, unit_team: int, arena_cell: Vector2i, trait_bonuses: Dictionary) -> CombatUnit:
	var unit := CombatUnit.new()
	unit.uid = instance.uid
	unit.def = instance.def
	unit.star = instance.star
	unit.team = unit_team
	unit.cell = arena_cell
	unit._build_stats(trait_bonuses)
	unit.hp = unit.stats["max_hp"]
	unit.shield = unit.stats["shield_flat"]
	unit.mana = unit.stats["mana_start"]
	return unit


## Compone le statistiche finali: base scalata per stella + bonus dei tratti
## attivi che si applicano a questa unità.
func _build_stats(trait_bonuses: Dictionary) -> void:
	var combat: Dictionary = GameData.balance()["combat"]

	stats = {
		"max_hp": def.stat_at_star("hp", star),
		"attack_damage": def.stat_at_star("attack_damage", star),
		"attack_speed": float(def.base_stats.get("attack_speed", 0.6)),
		"range": float(def.base_stats.get("range", 1)),
		"armor": float(def.base_stats.get("armor", 0)),
		"magic_resist": float(def.base_stats.get("magic_resist", 0)),
		"mana_max": float(def.base_stats.get("mana_max", 100)),
		"mana_start": float(def.base_stats.get("mana_start", 0)),
		"crit_chance": float(combat["base_crit_chance"]),
		"crit_damage": float(combat["base_crit_damage"]),
		"damage_reduction": 0.0,
		"omnivamp": 0.0,
		"cleave": 0.0,
		"max_hp_damage": 0.0,
		"charge_damage": 0.0,
		"regen_per_second": 0.0,
		"heal_power": 0.0,
		"move_speed_percent": 0.0,
		"rage_per_death": 0.0,
		"shield_flat": 0.0,
		"attack_speed_percent": 0.0,
		"attack_damage_percent": 0.0,
		"hp_percent": 0.0,
	}

	# I bonus arrivano già filtrati per questa unità (vedi TraitResolver).
	for stat_name in trait_bonuses:
		stats[stat_name] = float(stats.get(stat_name, 0.0)) + float(trait_bonuses[stat_name])

	# I moltiplicatori percentuali si applicano una volta sola, qui.
	stats["max_hp"] *= 1.0 + stats["hp_percent"]
	stats["attack_damage"] *= 1.0 + stats["attack_damage_percent"]


# --------------------------------------------------------------------------
# Statistiche effettive
# --------------------------------------------------------------------------

func base_stat(stat_name: String) -> float:
	return float(stats.get(stat_name, 0.0))


## Somma dei modificatori temporanei attivi su una statistica.
func _mod_sum(stat_name: String, now: float) -> float:
	var total := 0.0
	for mod in _mods:
		if mod["stat"] == stat_name and now < float(mod["until"]):
			total += float(mod["add"])
	return total


func stat(stat_name: String, now: float) -> float:
	return base_stat(stat_name) + _mod_sum(stat_name, now)


## Attacchi al secondo effettivi: base, più i bonus percentuali permanenti,
## temporanei e la furia gallica accumulata.
func effective_attack_speed(now: float) -> float:
	var percent := stat("attack_speed_percent", now)
	percent += rage_stacks * base_stat("rage_per_death")
	return maxf(0.1, base_stat("attack_speed") * (1.0 + percent))


func effective_range(now: float) -> int:
	return int(roundf(stat("range", now)))


func move_interval(now: float) -> float:
	var cells_per_second := float(GameData.balance()["combat"]["move_cells_per_second"])
	cells_per_second *= 1.0 + stat("move_speed_percent", now)
	return 1.0 / maxf(0.1, cells_per_second)


func add_mod(stat_name: String, amount: float, until: float) -> void:
	_mods.append({"stat": stat_name, "add": amount, "until": until})


func add_dot(damage_per_second: float, until: float, damage_type: int, source_uid: int) -> void:
	_dots.append({
		"dps": damage_per_second,
		"until": until,
		"type": damage_type,
		"source": source_uid,
	})


func active_dots(now: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for dot in _dots:
		if now < float(dot["until"]):
			result.append(dot)
	return result


## Rimuove i modificatori scaduti. Chiamata di rado: serve solo a evitare che
## gli array crescano senza limite in battaglie lunghe.
func prune(now: float) -> void:
	_mods = _mods.filter(func(mod): return now < float(mod["until"]))
	_dots = _dots.filter(func(dot): return now < float(dot["until"]))


# --------------------------------------------------------------------------
# Salute, scudo, mana
# --------------------------------------------------------------------------

func is_alive() -> bool:
	return state != State.DEAD and hp > 0.0


func is_stunned() -> bool:
	return stun_remaining > 0.0


func hp_ratio() -> float:
	return hp / maxf(1.0, base_stat("max_hp"))


func missing_hp() -> float:
	return maxf(0.0, base_stat("max_hp") - hp)


## Applica il danno già mitigato. Restituisce quanto è stato effettivamente
## tolto alla salute (lo scudo assorbe per primo).
func apply_damage(amount: float, now: float) -> float:
	if not is_alive():
		return 0.0
	var reduction := clampf(stat("damage_reduction", now), 0.0, 0.9)
	var incoming := amount * (1.0 - reduction)

	var absorbed: float = minf(shield, incoming)
	shield -= absorbed
	var to_hp := incoming - absorbed
	hp -= to_hp
	_damage_taken += incoming

	# Subire danno genera mana: è ciò che tiene vive le prime linee come
	# lanciatori di abilità e non solo come sacchi da pugni.
	var mana_gain := incoming * float(GameData.balance()["combat"]["mana_per_damage_taken"])
	gain_mana(mana_gain)

	if hp <= 0.0:
		hp = 0.0
		state = State.DEAD
	return to_hp


func heal(amount: float, now: float) -> float:
	if not is_alive():
		return 0.0
	var multiplier := 1.0 + stat("heal_power", now)
	var healed: float = minf(amount * multiplier, missing_hp())
	hp += healed
	return healed


func add_shield(amount: float) -> void:
	if is_alive():
		shield += amount


func gain_mana(amount: float) -> void:
	if is_alive():
		mana = minf(mana + amount, base_stat("mana_max"))


func is_ability_ready() -> bool:
	return is_alive() and not is_stunned() and mana >= base_stat("mana_max") and def.ability_type() != ""


func consume_mana() -> void:
	mana = float(GameData.balance()["combat"]["mana_cap_after_cast"])


func record_damage_dealt(amount: float) -> void:
	_damage_dealt += amount


func damage_dealt() -> float:
	return _damage_dealt


func damage_taken() -> float:
	return _damage_taken


## Mitigazione: armatura contro il fisico, resistenza magica contro il magico,
## il danno puro passa intero. La costante viene da balance.json.
func mitigate(amount: float, damage_type: int, now: float) -> float:
	if damage_type == DAMAGE_TRUE:
		return amount
	var resist := stat("armor", now) if damage_type == DAMAGE_PHYSICAL else stat("magic_resist", now)
	var constant := float(GameData.balance()["combat"]["armor_constant"])
	return amount * constant / (constant + maxf(0.0, resist))


func _to_string() -> String:
	return "%s %d★ (team %d) @%s" % [def.display_name, star, team, cell]
