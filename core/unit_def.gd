class_name UnitDef
extends RefCounted

## Definizione immutabile di un'unità, così come sta in data/units.json.
## Non contiene stato di partita: le istanze in campo sono CombatUnit.

var id: String
var display_name: String
var origin: String
var classes: PackedStringArray
var cost: int
var base_stats: Dictionary
var ability: Dictionary
var lore: String


static func from_dict(dict: Dictionary) -> UnitDef:
	var def := UnitDef.new()
	def.id = dict["id"]
	def.display_name = dict["name"]
	def.origin = dict["origin"]
	def.classes = PackedStringArray(dict.get("classes", []))
	def.cost = int(dict["cost"])
	def.base_stats = dict["stats"]
	def.ability = dict.get("ability", {})
	def.lore = String(dict.get("lore", ""))
	return def


## Tutti i tratti dell'unità: la civiltà più le classi.
func traits() -> PackedStringArray:
	var all := PackedStringArray([origin])
	all.append_array(classes)
	return all


func has_trait(trait_id: String) -> bool:
	return trait_id == origin or classes.has(trait_id)


## Statistica base scalata per stella. star è 1-based.
func stat_at_star(stat_name: String, star: int) -> float:
	var value := float(base_stats.get(stat_name, 0.0))
	var scaling: Array = GameData.balance()["star_scaling"].get(stat_name, [])
	if scaling.is_empty():
		return value
	var index: int = clampi(star - 1, 0, scaling.size() - 1)
	return value * float(scaling[index])


## Valore di un parametro dell'abilità. Se nel JSON è una terna, prende
## l'elemento corrispondente alla stella; se è uno scalare, lo restituisce
## invariato. Così il bilanciamento decide caso per caso cosa scala.
func ability_param(param: String, star: int, default_value = 0.0):
	var params: Dictionary = ability.get("params", {})
	if not params.has(param):
		return default_value
	var raw = params[param]
	if raw is Array:
		if raw.is_empty():
			return default_value
		return raw[clampi(star - 1, 0, raw.size() - 1)]
	return raw


func ability_type() -> String:
	return ability.get("type", "")


## Prezzo di vendita: sempre la cifra spesa per ottenere l'unità meno 1,
## a qualunque stella. Vendere fa quindi sempre perdere 1 oro rispetto
## all'investimento fatto.
func sell_value(star: int) -> int:
	var copies: int = int(pow(GameData.balance()["match"]["copies_to_upgrade"], star - 1))
	return cost * copies - 1
