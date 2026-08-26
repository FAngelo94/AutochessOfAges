class_name GameData
extends RefCounted

## Accesso ai file JSON di data/. Caricamento pigro e memorizzato: i JSON
## vengono letti una volta sola per esecuzione.
##
## Tutta la simulazione legge i numeri da qui, mai da costanti sparse nel
## codice: il bilanciamento si tocca in data/, non in core/.

const UNITS_PATH := "res://data/units.json"
const TRAITS_PATH := "res://data/traits.json"
const BALANCE_PATH := "res://data/balance.json"
const HEROES_PATH := "res://data/heroes.json"
const TUTORIAL_PATH := "res://data/tutorial.json"

const DEFAULT_HERO_ID := "cesare"

static var _units_by_id: Dictionary = {}
static var _traits: Dictionary = {}
static var _balance: Dictionary = {}
static var _heroes_by_id: Dictionary = {}
static var _tutorial: Dictionary = {}
static var _loaded := false


static func _load_json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("GameData: impossibile leggere %s (errore %d)" % [path, FileAccess.get_open_error()])
		return {}
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("GameData: %s non contiene un oggetto JSON valido" % path)
		return {}
	return parsed


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_balance = _load_json(BALANCE_PATH)
	_traits = _load_json(TRAITS_PATH)
	var units_file := _load_json(UNITS_PATH)
	for entry in units_file.get("units", []):
		var def := UnitDef.from_dict(entry)
		_units_by_id[def.id] = def
	var heroes_file := _load_json(HEROES_PATH)
	for entry in heroes_file.get("heroes", []):
		var hdef := HeroDef.from_dict(entry)
		_heroes_by_id[hdef.id] = hdef
	_tutorial = _load_json(TUTORIAL_PATH)


## Ricarica i JSON da disco. Utile per iterare sul bilanciamento senza
## riavviare l'editor.
static func reload() -> void:
	_loaded = false
	_units_by_id.clear()
	_traits.clear()
	_balance.clear()
	_heroes_by_id.clear()
	_tutorial.clear()
	ensure_loaded()


static func balance() -> Dictionary:
	ensure_loaded()
	return _balance


static func unit(unit_id: String) -> UnitDef:
	ensure_loaded()
	if not _units_by_id.has(unit_id):
		push_error("GameData: unità sconosciuta '%s'" % unit_id)
		return null
	return _units_by_id[unit_id]


static func all_units() -> Array[UnitDef]:
	ensure_loaded()
	var result: Array[UnitDef] = []
	for def in _units_by_id.values():
		result.append(def)
	# Ordine stabile: il pool e la generazione dello shop dipendono
	# dall'ordinamento, e Dictionary.values() non lo garantisce nel tempo.
	result.sort_custom(func(a: UnitDef, b: UnitDef) -> bool:
		if a.cost != b.cost:
			return a.cost < b.cost
		return a.id < b.id)
	return result


static func units_of_cost(cost: int) -> Array[UnitDef]:
	var result: Array[UnitDef] = []
	for def in all_units():
		if def.cost == cost:
			result.append(def)
	return result


static func has_unit(unit_id: String) -> bool:
	ensure_loaded()
	return _units_by_id.has(unit_id)


static func hero(hero_id: String) -> HeroDef:
	ensure_loaded()
	if not _heroes_by_id.has(hero_id):
		push_error("GameData: eroe sconosciuto '%s'" % hero_id)
		return null
	return _heroes_by_id[hero_id]


static func has_hero(hero_id: String) -> bool:
	ensure_loaded()
	return _heroes_by_id.has(hero_id)


static func all_heroes() -> Array[HeroDef]:
	ensure_loaded()
	var result: Array[HeroDef] = []
	for def in _heroes_by_id.values():
		result.append(def)
	result.sort_custom(func(a: HeroDef, b: HeroDef) -> bool:
		return a.id < b.id)
	return result


static func hero_ids() -> Array:
	ensure_loaded()
	var ids := _heroes_by_id.keys()
	ids.sort()
	return ids


## Definizione di un tratto, cercata prima tra le civiltà e poi tra le classi.
static func trait_def(trait_id: String) -> Dictionary:
	ensure_loaded()
	var origins: Dictionary = _traits.get("origins", {})
	if origins.has(trait_id):
		return origins[trait_id]
	var classes: Dictionary = _traits.get("classes", {})
	if classes.has(trait_id):
		return classes[trait_id]
	return {}


static func is_origin(trait_id: String) -> bool:
	ensure_loaded()
	return _traits.get("origins", {}).has(trait_id)


static func origin_ids() -> Array:
	ensure_loaded()
	var ids: Array = _traits.get("origins", {}).keys()
	ids.sort()
	return ids


static func class_ids() -> Array:
	ensure_loaded()
	var ids: Array = _traits.get("classes", {}).keys()
	ids.sort()
	return ids


## Soglia attiva di un tratto dato il numero di unità distinte che lo portano.
## Restituisce {} se nessuna soglia è raggiunta.
static func active_tier(trait_id: String, count: int) -> Dictionary:
	var def := trait_def(trait_id)
	var active := {}
	for tier in def.get("tiers", []):
		if count >= int(tier["count"]):
			active = tier
	return active


static func trait_name(trait_id: String) -> String:
	return trait_def(trait_id).get("name", trait_id)


## Probabilità di pescare le varie fasce di costo a un dato livello squadra.
static func shop_odds(level: int) -> Array:
	var odds: Dictionary = balance()["shop_odds"]
	var key := str(clampi(level, 1, balance()["levels"]["max_level"]))
	return odds.get(key, [1.0, 0.0, 0.0, 0.0, 0.0])


static func tutorial() -> Dictionary:
	ensure_loaded()
	return _tutorial


## Capitoli della schermata Guida, nell'ordine in cui compaiono nel JSON.
static func guide_sections() -> Array:
	ensure_loaded()
	return _tutorial.get("guide", [])


## Testo di un suggerimento one-shot per id. {} se l'id non esiste, così un
## errore di battitura nel codice chiamante non fa comparire una bolla vuota.
static func tip(tip_id: String) -> Dictionary:
	ensure_loaded()
	var tips: Dictionary = _tutorial.get("tips", {})
	return tips.get(tip_id, {})
