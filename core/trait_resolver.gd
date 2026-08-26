class_name TraitResolver
extends RefCounted

## Traduce una formazione nei bonus effettivi da applicare a ogni unità.
##
## Regole del genere rispettate qui:
## - contano le unità DISTINTE (due copie dello stesso Legionario valgono 1);
## - di un tratto vale solo la soglia più alta raggiunta, non la somma;
## - 'scope' nel JSON decide se il bonus tocca tutta la squadra o solo chi
##   porta il tratto.

## Restituisce {trait_id: numero di unità distinte}.
static func count_traits(board_units: Array[UnitInstance]) -> Dictionary:
	var seen := {}
	var counts := {}
	for unit in board_units:
		if seen.has(unit.def.id):
			continue
		seen[unit.def.id] = true
		for trait_id in unit.def.traits():
			counts[trait_id] = int(counts.get(trait_id, 0)) + 1
	return counts


## Restituisce {trait_id: tier} per i soli tratti che hanno una soglia attiva.
static func active_tiers(counts: Dictionary) -> Dictionary:
	var result := {}
	for trait_id in counts:
		var tier := GameData.active_tier(trait_id, int(counts[trait_id]))
		if not tier.is_empty():
			result[trait_id] = tier
	return result


## Bonus da applicare a ciascuna unità: {uid: {stat: valore}}.
static func bonuses_by_uid(board_units: Array[UnitInstance]) -> Dictionary:
	var counts := count_traits(board_units)
	var tiers := active_tiers(counts)

	var result := {}
	for unit in board_units:
		result[unit.uid] = {}

	for trait_id in tiers:
		var tier: Dictionary = tiers[trait_id]
		var scope := String(tier.get("scope", "trait"))
		for unit in board_units:
			if scope != "all" and not unit.def.has_trait(trait_id):
				continue
			var bonuses: Dictionary = result[unit.uid]
			for effect in tier.get("effects", []):
				var stat_name := String(effect["stat"])
				bonuses[stat_name] = float(bonuses.get(stat_name, 0.0)) + float(effect["add"])

	return result


## Riepilogo leggibile per la UI: una riga per tratto presente in formazione,
## ordinata mettendo prima le sinergie attive.
static func summary(board_units: Array[UnitInstance]) -> Array[Dictionary]:
	var counts := count_traits(board_units)
	var rows: Array[Dictionary] = []

	for trait_id in counts:
		var count := int(counts[trait_id])
		var def := GameData.trait_def(trait_id)
		var tier := GameData.active_tier(trait_id, count)
		var next_at := 0
		for candidate in def.get("tiers", []):
			if count < int(candidate["count"]):
				next_at = int(candidate["count"])
				break
		rows.append({
			"id": trait_id,
			"name": def.get("name", trait_id),
			"is_origin": GameData.is_origin(trait_id),
			"count": count,
			"active": not tier.is_empty(),
			"tier_count": int(tier.get("count", 0)),
			"text": String(tier.get("text", def.get("description", ""))),
			"next_threshold": next_at,
		})

	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["active"] != b["active"]:
			return a["active"]
		if a["count"] != b["count"]:
			return a["count"] > b["count"]
		return a["id"] < b["id"])
	return rows
