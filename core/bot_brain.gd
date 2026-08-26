class_name BotBrain
extends RefCounted

## IA degli avversari nella fase di preparazione.
##
## Non prova a giocare bene in senso assoluto: prova a giocare in modo
## plausibile e vario, così le partite in singolo somigliano a una lobby vera.
## Ogni bot ha una civiltà preferita e una soglia di oro sotto la quale non
## scende, che ne definiscono lo stile.

var player: Player
var favourite_origin: String
var economy_floor: int
var aggression: float

var _rng: SimRNG


func _init(target: Player, rng: SimRNG) -> void:
	player = target
	_rng = rng
	favourite_origin = String(_rng.pick(GameData.origin_ids()))
	# Chi tiene 50 gioca l'economia, chi tiene 10 spinge sul livello.
	economy_floor = [10, 30, 50][_rng.randi_range_ex(0, 3)]
	aggression = _rng.randf_ex()


## Esegue il turno di preparazione del bot.
func play_preparation(stage: int) -> void:
	if not player.is_alive():
		return

	_buy_from_shop()
	_maybe_level_up(stage)
	_maybe_reroll(stage)
	_arrange_board()


## Compra ciò che serve, in ordine di priorità: copie che completano un
## potenziamento, poi unità della civiltà preferita, poi il resto.
func _buy_from_shop() -> void:
	for slot in player.shop.size():
		var def: UnitDef = player.shop[slot]
		if def == null:
			continue
		if not player.can_buy(slot):
			continue
		if player.gold - def.cost < _reserve(def):
			continue
		if _wants(def):
			player.buy(slot)


## Oro che il bot vuole conservare dopo l'acquisto.
##
## Finché il campo non è pieno non conserva nulla: un bot che risparmia con la
## griglia mezza vuota perde i round senza motivo, e nei primi turni — quando
## si hanno pochi spiccioli — non comprerebbe proprio niente.
func _reserve(def: UnitDef) -> int:
	if _completes_upgrade(def.id):
		return 0
	if player.board_count() < player.max_board_units():
		return 0
	return economy_floor


func _wants(def: UnitDef) -> bool:
	if _completes_upgrade(def.id):
		return true
	if _owned_copies(def.id) > 0:
		return true
	if def.origin == favourite_origin:
		return true
	# Le unità costose sono sempre appetibili, le altre solo se c'è spazio.
	return def.cost >= 4 or player.board_count() < player.max_board_units()


func _owned_copies(unit_id: String) -> int:
	var count := 0
	for unit in player.units:
		if unit.def.id == unit_id:
			count += 1
	return count


func _completes_upgrade(unit_id: String) -> bool:
	var needed := int(GameData.balance()["match"]["copies_to_upgrade"])
	var ones := 0
	for unit in player.units:
		if unit.def.id == unit_id and unit.star == 1:
			ones += 1
	return ones + 1 >= needed


## Sale di livello quando è indietro rispetto allo stage o quando ha oro in
## eccesso: è la decisione che più distingue i bot fra loro.
func _maybe_level_up(stage: int) -> void:
	var target_level := clampi(stage + 2, 3, int(GameData.balance()["levels"]["max_level"]))
	if player.level >= target_level:
		return
	var budget := player.gold - economy_floor
	var spent := 0
	while budget > 0 and player.level < target_level and player.buy_xp():
		spent += int(GameData.balance()["economy"]["buy_xp_cost"])
		budget = player.gold - economy_floor
		if spent > 20:
			break


## Fa reroll solo con oro abbondante, tanto più volentieri quanto è aggressivo.
func _maybe_reroll(stage: int) -> void:
	var spare := player.gold - economy_floor - 10
	var rolls := 0
	var max_rolls := int(2 + aggression * 4 + stage / 2)
	while spare >= player.reroll_cost() and rolls < max_rolls:
		if not _rng.chance(0.4 + aggression * 0.4):
			break
		if not player.reroll():
			break
		_buy_from_shop()
		rolls += 1
		spare = player.gold - economy_floor - 10


## Schiera le unità migliori e le dispone su due linee: corpo a corpo davanti,
## gittata dietro. È la stessa euristica che userebbe un giocatore alle prime
## armi, ed è sufficiente perché i bot non regalino i round.
func _arrange_board() -> void:
	var roster := player.units.duplicate()
	roster.sort_custom(func(a: UnitInstance, b: UnitInstance) -> bool:
		var value_a := a.def.cost * a.star * a.star + (2 if a.def.origin == favourite_origin else 0)
		var value_b := b.def.cost * b.star * b.star + (2 if b.def.origin == favourite_origin else 0)
		return value_a > value_b)

	var capacity := player.max_board_units()
	var deployed := roster.slice(0, capacity)
	var benched := roster.slice(capacity)

	for unit in benched:
		if unit.is_on_board():
			player.move_to_bench(unit)

	var columns := int(GameData.balance()["match"]["board_columns"])
	var front_x := 0
	var back_x := 0

	for unit in deployed:
		var is_melee := float(unit.def.base_stats.get("range", 1)) <= 2.0
		var cell := Vector2i.ZERO
		if is_melee:
			cell = Vector2i(_spread(front_x, columns), 0)
			front_x += 1
		else:
			cell = Vector2i(_spread(back_x, columns), 3)
			back_x += 1
		if player.unit_at_cell(cell) != null and player.unit_at_cell(cell) != unit:
			cell = _first_free_cell()
			if cell == Vector2i(-1, -1):
				continue
		player.move_to_board(unit, cell)


## Riempie la fila partendo dal centro verso i bordi: le unità al centro
## entrano in contatto prima e assorbono meglio la carica avversaria.
func _spread(index: int, columns: int) -> int:
	var centre := columns / 2
	var offset := (index + 1) / 2
	return clampi(centre + (offset if index % 2 == 0 else -offset), 0, columns - 1)


func _first_free_cell() -> Vector2i:
	var match_data: Dictionary = GameData.balance()["match"]
	for y in int(match_data["board_rows"]):
		for x in int(match_data["board_columns"]):
			var cell := Vector2i(x, y)
			if player.unit_at_cell(cell) == null:
				return cell
	return Vector2i(-1, -1)
