class_name UnitInstance
extends RefCounted

## Un'unità posseduta da un giocatore, fuori dal combattimento: che unità è,
## a che stella, e dove si trova (panchina o griglia).
##
## In combattimento viene convertita in CombatUnit, che è usa e getta: così
## una battaglia non può mai corrompere lo stato della squadra.

enum Location { BENCH, BOARD }

var def: UnitDef
var star: int = 1
var location: int = Location.BENCH
## Indice di panchina se location == BENCH, altrimenti -1.
var bench_slot: int = -1
## Cella della griglia se location == BOARD, altrimenti Vector2i(-1, -1).
var cell: Vector2i = Vector2i(-1, -1)
## Identificatore univoco all'interno della partita: serve alla UI per seguire
## la stessa unità tra un round e l'altro senza confonderla con un duplicato.
var uid: int = 0


static func create(unit_def: UnitDef, star_level: int = 1) -> UnitInstance:
	var instance := UnitInstance.new()
	instance.def = unit_def
	instance.star = star_level
	return instance


func is_on_board() -> bool:
	return location == Location.BOARD


func place_on_board(target_cell: Vector2i) -> void:
	location = Location.BOARD
	cell = target_cell
	bench_slot = -1


func place_on_bench(slot: int) -> void:
	location = Location.BENCH
	bench_slot = slot
	cell = Vector2i(-1, -1)


## Quante copie di livello 1 questa unità rappresenta: serve a restituirle
## tutte al pool condiviso quando viene venduta.
func copies_worth() -> int:
	return int(pow(GameData.balance()["match"]["copies_to_upgrade"], star - 1))


func sell_value() -> int:
	return def.sell_value(star)


func duplicate_instance() -> UnitInstance:
	var copy := UnitInstance.create(def, star)
	copy.location = location
	copy.bench_slot = bench_slot
	copy.cell = cell
	copy.uid = uid
	return copy


func _to_string() -> String:
	return "%s %d★" % [def.display_name, star]
