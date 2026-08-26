class_name UnitPool
extends RefCounted

## Pool CONDIVISO delle copie disponibili in partita.
##
## È la meccanica di contesa nascosta del genere: le copie sono finite e tutti
## i giocatori pescano dallo stesso serbatoio. Se tre avversari stanno salendo
## sullo stesso Legionario, tu lo vedrai comparire sempre più di rado.

## unit_id -> copie ancora disponibili
var _available: Dictionary = {}


func _init() -> void:
	reset()


func reset() -> void:
	_available.clear()
	var copies_per_cost: Dictionary = GameData.balance()["pool"]["copies_per_cost"]
	for def in GameData.all_units():
		_available[def.id] = int(copies_per_cost.get(str(def.cost), 0))


func available(unit_id: String) -> int:
	return int(_available.get(unit_id, 0))


func total_available_of_cost(cost: int) -> int:
	var total := 0
	for def in GameData.units_of_cost(cost):
		total += available(def.id)
	return total


## Estrae una copia. Restituisce false se il pool è esaurito per quell'unità.
func take(unit_id: String, count: int = 1) -> bool:
	if available(unit_id) < count:
		return false
	_available[unit_id] = available(unit_id) - count
	return true


## Restituisce copie al pool (vendita, o unità rimasta invenduta nello shop).
func give_back(unit_id: String, count: int = 1) -> void:
	if not _available.has(unit_id):
		push_error("UnitPool: unità sconosciuta '%s'" % unit_id)
		return
	_available[unit_id] = available(unit_id) + count


## Pesca un'unità di un dato costo, con probabilità proporzionale alle copie
## rimaste: un'unità già molto acquistata dagli avversari esce più di rado.
## La copia pescata viene RISERVATA (tolta dal pool) finché resta in vetrina:
## due giocatori non possono vedere la stessa copia nello stesso momento.
## Chi non la compra la restituisce al prossimo aggiornamento dello shop.
## Restituisce null se non resta nulla di quel costo.
func draw_of_cost(cost: int, rng: SimRNG) -> UnitDef:
	var candidates := GameData.units_of_cost(cost)
	var weights: Array = []
	var total := 0
	for def in candidates:
		var count := available(def.id)
		weights.append(float(count))
		total += count
	if total <= 0:
		return null
	var drawn: UnitDef = candidates[rng.pick_weighted(weights)]
	take(drawn.id)
	return drawn


## Pesca rispettando le probabilità per livello, con fallback verso i costi
## più bassi se la fascia estratta è esaurita.
func draw_for_level(level: int, rng: SimRNG) -> UnitDef:
	var odds := GameData.shop_odds(level)
	var cost_index := rng.pick_weighted(odds)
	for offset in range(odds.size()):
		var cost := cost_index + 1 - offset
		if cost >= 1:
			var def := draw_of_cost(cost, rng)
			if def != null:
				return def
	return null


func snapshot() -> Dictionary:
	return _available.duplicate()
