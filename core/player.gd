class_name Player
extends RefCounted

## Stato di un giocatore durante la fase di preparazione: oro, vita, livello,
## panchina, griglia e negozio.
##
## Nessun riferimento alla UI e nessun segnale: tutte le azioni sono metodi che
## restituiscono un esito. Domani il server potrà chiamare gli stessi metodi
## dopo aver validato un comando ricevuto dal client.

signal changed

var index: int = 0
var display_name: String = "Giocatore"
var is_bot: bool = false
## Id dell'eroe scelto, o "" per nessun eroe. Il default "cesare" è una
## regola di menu/match-setup (Profile.effective_hero()), non del costruttore:
## i test esistenti su Player.new() grezzi assumono nessun bonus eroe.
var hero_id: String = ""

var hp: int
var gold: int
var level: int
var xp: int

## Vittorie/sconfitte consecutive: positivo = serie di vittorie.
var streak: int = 0
var last_round_won: bool = false
var eliminated: bool = false
var placement: int = 0

## Unità possedute (panchina + griglia), tutte le UnitInstance.
var units: Array[UnitInstance] = []
## Offerte correnti: UnitDef, oppure null per uno slot già comprato.
var shop: Array = []

var _pool: UnitPool
var _rng: SimRNG
var _next_uid: int = 1


func _init(pool: UnitPool, rng: SimRNG) -> void:
	_pool = pool
	_rng = rng
	var balance := GameData.balance()
	hp = int(balance["match"]["starting_hp"])
	gold = int(balance["economy"]["starting_gold"])
	level = int(balance["levels"]["starting_level"])
	xp = int(balance["levels"]["starting_xp"])
	shop.resize(int(balance["match"]["shop_slots"]))


# --------------------------------------------------------------------------
# Interrogazioni
# --------------------------------------------------------------------------

func board_units() -> Array[UnitInstance]:
	var result: Array[UnitInstance] = []
	for unit in units:
		if unit.is_on_board():
			result.append(unit)
	return result


func bench_units() -> Array[UnitInstance]:
	var result: Array[UnitInstance] = []
	for unit in units:
		if not unit.is_on_board():
			result.append(unit)
	return result


func max_board_units() -> int:
	var per_level: Array = GameData.balance()["levels"]["units"]
	return int(per_level[clampi(level - 1, 0, per_level.size() - 1)])


func board_count() -> int:
	return board_units().size()


func can_deploy_more() -> bool:
	return board_count() < max_board_units()


func bench_size() -> int:
	return int(GameData.balance()["match"]["bench_size"])


func free_bench_slot() -> int:
	var taken := {}
	for unit in bench_units():
		taken[unit.bench_slot] = true
	for slot in bench_size():
		if not taken.has(slot):
			return slot
	return -1


func bench_is_full() -> bool:
	return free_bench_slot() == -1


func unit_at_cell(cell: Vector2i) -> UnitInstance:
	for unit in board_units():
		if unit.cell == cell:
			return unit
	return null


func unit_by_uid(uid: int) -> UnitInstance:
	for unit in units:
		if unit.uid == uid:
			return unit
	return null


func is_alive() -> bool:
	return hp > 0 and not eliminated


## Conteggio dei tratti attivi: contano le unità DISTINTE schierate sulla
## griglia (due copie della stessa unità valgono uno, come da genere).
func active_traits() -> Dictionary:
	var seen_ids := {}
	var counts := {}
	for unit in board_units():
		if seen_ids.has(unit.def.id):
			continue
		seen_ids[unit.def.id] = true
		for trait_id in unit.def.traits():
			counts[trait_id] = int(counts.get(trait_id, 0)) + 1
	return counts


func xp_to_next_level() -> int:
	var table: Array = GameData.balance()["levels"]["xp_to_next"]
	if level - 1 >= table.size():
		return 0
	return int(table[level - 1])


func is_max_level() -> bool:
	return level >= int(GameData.balance()["levels"]["max_level"])


# --------------------------------------------------------------------------
# Negozio
# --------------------------------------------------------------------------

## Rigenera le offerte. Le unità non acquistate tornano nel pool condiviso.
func refresh_shop(return_unsold: bool = true) -> void:
	if return_unsold:
		for offer in shop:
			if offer != null:
				_pool.give_back(offer.id)
	for slot in shop.size():
		shop[slot] = _pool.draw_for_level(level, _rng)
	changed.emit()


func reroll_cost() -> int:
	return int(GameData.balance()["economy"]["reroll_cost"])


func can_reroll() -> bool:
	return gold >= reroll_cost()


func reroll() -> bool:
	if not can_reroll():
		return false
	gold -= reroll_cost()
	refresh_shop()
	return true


func can_buy(slot: int) -> bool:
	if slot < 0 or slot >= shop.size() or shop[slot] == null:
		return false
	var def: UnitDef = shop[slot]
	if gold < def.cost:
		return false
	# Se la panchina è piena si può comprare solo se l'acquisto completa
	# subito un potenziamento: altrimenti l'unità non avrebbe dove stare.
	if bench_is_full() and not _would_upgrade(def.id):
		return false
	return true


func buy(slot: int) -> UnitInstance:
	if not can_buy(slot):
		return null
	var def: UnitDef = shop[slot]
	gold -= def.cost
	shop[slot] = null
	var unit := _add_unit(def, 1)
	changed.emit()
	return unit


## Vera se comprare un'altra copia di unit_id fa scattare un potenziamento.
func _would_upgrade(unit_id: String) -> bool:
	var needed := int(GameData.balance()["match"]["copies_to_upgrade"])
	var ones := 0
	for unit in units:
		if unit.def.id == unit_id and unit.star == 1:
			ones += 1
	return ones + 1 >= needed


func sell(unit: UnitInstance) -> bool:
	var position := units.find(unit)
	if position == -1:
		return false
	gold += unit.sell_value()
	_pool.give_back(unit.def.id, unit.copies_worth())
	units.remove_at(position)
	changed.emit()
	return true


func sell_by_uid(uid: int) -> bool:
	var unit := unit_by_uid(uid)
	return sell(unit) if unit != null else false


# --------------------------------------------------------------------------
# Livello ed esperienza
# --------------------------------------------------------------------------

func buy_xp() -> bool:
	var economy: Dictionary = GameData.balance()["economy"]
	var cost := int(economy["buy_xp_cost"])
	if gold < cost or is_max_level():
		return false
	gold -= cost
	add_xp(int(economy["buy_xp_amount"]))
	return true


func add_xp(amount: int) -> void:
	if is_max_level():
		return
	xp += amount
	while not is_max_level() and xp >= xp_to_next_level():
		xp -= xp_to_next_level()
		level += 1
	if is_max_level():
		xp = 0
	changed.emit()


# --------------------------------------------------------------------------
# Economia di fine round
# --------------------------------------------------------------------------

## Reddito di fine round: base + interessi + bonus vittoria + serie.
## Restituisce il dettaglio, che la UI mostra al giocatore.
func grant_round_income(won: bool) -> Dictionary:
	var economy: Dictionary = GameData.balance()["economy"]

	var base := int(economy["base_income"])
	var interest: int = mini(gold / int(economy["interest_per"]), int(economy["max_interest"]))
	var win_bonus := int(economy["win_bonus"]) if won else 0

	# La serie si aggiorna prima di calcolarne il bonus.
	if won:
		streak = maxi(streak, 0) + 1
	else:
		streak = mini(streak, 0) - 1
	var streak_bonus := 0
	for threshold in economy["streak_thresholds"]:
		if absi(streak) >= int(threshold["streak"]):
			streak_bonus = int(threshold["gold"])

	var hero_bonus := 0
	if not won and hero_id == "cesare":
		var params: Dictionary = GameData.hero("cesare").ability_params
		hero_bonus = _rng.randi_range_ex(int(params["min"]), int(params["max"]) + 1)

	var total := base + interest + win_bonus + streak_bonus + hero_bonus
	gold += total
	last_round_won = won
	add_xp(int(GameData.balance()["levels"]["xp_per_round"]))
	changed.emit()

	return {
		"base": base,
		"interest": interest,
		"win_bonus": win_bonus,
		"streak_bonus": streak_bonus,
		"hero_bonus": hero_bonus,
		"streak": streak,
		"total": total,
	}


func take_damage(amount: int) -> void:
	hp = maxi(0, hp - amount)
	if hp == 0:
		eliminated = true
	changed.emit()


# --------------------------------------------------------------------------
# Posizionamento
# --------------------------------------------------------------------------

## Sposta un'unità su una cella della griglia. Se la cella è occupata, le due
## unità si scambiano di posto; se arriva dalla panchina e la griglia è piena,
## lo spostamento fallisce.
func move_to_board(unit: UnitInstance, cell: Vector2i) -> bool:
	if not _is_valid_cell(cell):
		return false
	var occupant := unit_at_cell(cell)
	if occupant == unit:
		return true
	if not unit.is_on_board() and not can_deploy_more() and occupant == null:
		return false

	var from_cell := unit.cell
	var from_slot := unit.bench_slot
	var was_on_board := unit.is_on_board()

	unit.place_on_board(cell)
	if occupant != null:
		if was_on_board:
			occupant.place_on_board(from_cell)
		else:
			occupant.place_on_bench(from_slot)
	changed.emit()
	return true


func move_to_bench(unit: UnitInstance, slot: int = -1) -> bool:
	if slot == -1:
		slot = free_bench_slot()
	if slot < 0 or slot >= bench_size():
		return false
	var occupant: UnitInstance = null
	for other in bench_units():
		if other.bench_slot == slot:
			occupant = other
			break
	if occupant == unit:
		return true

	var from_cell := unit.cell
	var from_slot := unit.bench_slot
	var was_on_board := unit.is_on_board()

	unit.place_on_bench(slot)
	if occupant != null:
		if was_on_board:
			occupant.place_on_board(from_cell)
		else:
			occupant.place_on_bench(from_slot)
	changed.emit()
	return true


func _is_valid_cell(cell: Vector2i) -> bool:
	var match_data: Dictionary = GameData.balance()["match"]
	return cell.x >= 0 and cell.x < int(match_data["board_columns"]) \
		and cell.y >= 0 and cell.y < int(match_data["board_rows"])


# --------------------------------------------------------------------------
# Acquisizione e potenziamento
# --------------------------------------------------------------------------

## Aggiunge un'unità e applica a cascata i potenziamenti che ne derivano.
func _add_unit(def: UnitDef, star: int) -> UnitInstance:
	var unit := UnitInstance.create(def, star)
	unit.uid = _next_uid
	_next_uid += 1

	var slot := free_bench_slot()
	if slot == -1:
		# Nessuno slot libero: è ammesso solo perché l'acquisto completa un
		# potenziamento, quindi l'unità sparisce subito nella fusione.
		unit.place_on_bench(-1)
	else:
		unit.place_on_bench(slot)
	units.append(unit)

	var upgraded := _try_upgrade(def.id, star)
	return upgraded if upgraded != null else unit


## Fonde le copie quando se ne raggiungono abbastanza. Ricorsiva: tre unità a
## 2★ create dalla stessa catena diventano immediatamente una 3★.
func _try_upgrade(unit_id: String, star: int) -> UnitInstance:
	var needed := int(GameData.balance()["match"]["copies_to_upgrade"])
	var max_star := int(GameData.balance()["match"]["max_star"])
	if star >= max_star:
		return null

	var matching: Array[UnitInstance] = []
	for unit in units:
		if unit.def.id == unit_id and unit.star == star:
			matching.append(unit)
	if matching.size() < needed:
		return null

	# L'unità potenziata eredita la posizione migliore tra quelle fuse: se una
	# delle copie era schierata, la nuova resta in campo al suo posto.
	var inherit: UnitInstance = matching[0]
	for unit in matching:
		if unit.is_on_board():
			inherit = unit
			break

	for i in needed:
		units.erase(matching[i])

	if hero_id == "vercingetorige":
		var params: Dictionary = GameData.hero("vercingetorige").ability_params
		gold += int(params["gold_per_merge"])
		changed.emit()

	var upgraded := UnitInstance.create(GameData.unit(unit_id), star + 1)
	upgraded.uid = _next_uid
	_next_uid += 1
	if inherit.is_on_board():
		upgraded.place_on_board(inherit.cell)
	else:
		var slot := inherit.bench_slot if inherit.bench_slot >= 0 else free_bench_slot()
		upgraded.place_on_bench(slot)
	units.append(upgraded)

	var further := _try_upgrade(unit_id, star + 1)
	return further if further != null else upgraded


## Aggiunge un'unità senza pagarla e senza toccare il pool: per i round contro
## i mostri neutrali, i test e i comandi di debug.
func grant_unit(unit_id: String, star: int = 1) -> UnitInstance:
	return _add_unit(GameData.unit(unit_id), star)
