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


## Copie che quella fascia di costo aveva a inizio partita. Ricavata dai dati,
## non memorizzata: così non c'è uno stato in più da serializzare e da tenere
## allineato fra server e client.
func initial_capacity_of_cost(cost: int) -> int:
	var copies_per_cost: Dictionary = GameData.balance()["pool"]["copies_per_cost"]
	return GameData.units_of_cost(cost).size() * int(copies_per_cost.get(str(cost), 0))


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


## Peso di ogni fascia di costo a un dato livello: la riga di `shop_odds`
## corretta per le copie che alla fascia restano davvero.
##
##   peso = odds * (residuo / capacità iniziale) ^ esponente
##
## A pool intatto il residuo vale 1 ovunque e i pesi coincidono con la tabella,
## che resta la verità dichiarata a inizio partita; man mano che una fascia si
## svuota il suo peso cala e si redistribuisce sulle altre. Una fascia a zero
## pesa zero QUALUNQUE sia l'esponente — `pow(0, 0)` vale 1, quindi il caso va
## intercettato prima — ed è ciò che rende inutile un fallback verso i costi
## più bassi.
##
## `exponent` negativo significa "quello configurato": i test possono passare
## 0.0 o 1.0 espliciti senza dover toccare il balance.json vero.
func band_weights(level: int, exponent: float = -1.0) -> Array:
	var odds := GameData.shop_odds(level)
	var power := GameData.pool_scarcity_exponent() if exponent < 0.0 else exponent
	var weights: Array = []
	for index in odds.size():
		var cost := index + 1
		var capacity := initial_capacity_of_cost(cost)
		var remaining := total_available_of_cost(cost)
		if capacity <= 0 or remaining <= 0:
			weights.append(0.0)
			continue
		weights.append(float(odds[index]) * pow(float(remaining) / float(capacity), power))
	return weights


## Pesca rispettando le probabilità per livello, pesate sul residuo del pool
## (vedi `band_weights`). Restituisce null solo se il pool è esaurito ovunque:
## una fascia con peso maggiore di zero ha per costruzione almeno una copia,
## quindi `draw_of_cost` non può fallire.
func draw_for_level(level: int, rng: SimRNG) -> UnitDef:
	var weights := band_weights(level)
	var total := 0.0
	for weight in weights:
		total += float(weight)
	# Il controllo sta PRIMA di pick_weighted, che ha un assert sulla somma.
	if total <= 0.0:
		return null
	return draw_of_cost(rng.pick_weighted(weights) + 1, rng)


func snapshot() -> Dictionary:
	return _available.duplicate()


## Ripristina lo stato del pool da uno snapshot (per apply_dict lato client).
func restore(snapshot: Dictionary) -> void:
	_available = snapshot.duplicate()
