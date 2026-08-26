class_name HeroDef
extends RefCounted

## Definizione immutabile di un eroe, così come sta in data/heroes.json.
## Gli eroi non sono unità: non entrano nel pool condiviso, danno solo un
## bonus economico al giocatore che li ha selezionati.

var id: String
var display_name: String
var origin: String
var ability_type: String
var ability_params: Dictionary
var ability_text: String
var lore: String


static func from_dict(dict: Dictionary) -> HeroDef:
	var def := HeroDef.new()
	def.id = dict["id"]
	def.display_name = dict["name"]
	def.origin = dict["origin"]
	def.ability_type = String(dict.get("ability_type", ""))
	def.ability_params = dict.get("ability_params", {})
	def.ability_text = String(dict.get("ability_text", ""))
	def.lore = String(dict.get("lore", ""))
	return def
