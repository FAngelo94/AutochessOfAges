extends SceneTree

## Suite di test del motore, eseguibile senza aprire l'editor:
##
##   godot --headless --path . --script res://tests/run_tests.gd
##
## Il test più importante è quello sul determinismo: se cade, il multiplayer
## autoritativo non è più possibile e i test di bilanciamento non valgono nulla.

var _passed := 0
var _failed := 0


func _initialize() -> void:
	GameData.ensure_loaded()

	_test_data_integrity()
	_test_hex_grid()
	_test_rng_determinism()
	_test_pool_conservation()
	_test_upgrade_cascade()
	_test_economy()
	_test_combat_determinism()
	_test_traits()
	_test_full_match()
	_test_replay_log()
	_test_monetization()

	print("\n%d superati, %d falliti" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % label)
	else:
		_failed += 1
		printerr("  FAIL %s%s" % [label, ("  -> " + detail) if detail != "" else ""])


func section(title: String) -> void:
	print("\n== %s ==" % title)


# --------------------------------------------------------------------------

## La griglia esagonale sta sotto a movimento, gittate e bersagli: se sbaglia,
## sbaglia tutto il combattimento in modi difficili da ricondurre alla causa.
func _test_hex_grid() -> void:
	section("Griglia esagonale")

	check(Hex.distance(Vector2i(2, 2), Vector2i(2, 2)) == 0, "una cella dista zero da se stessa")

	# Ogni vicino dista esattamente un passo, su righe pari e dispari: è qui che
	# le formule scritte in coordinate offset sbagliano, perché lo scarto di
	# mezza cella cambia segno con la parità della riga.
	var all_adjacent := true
	var neighbour_count_ok := true
	for row in 6:
		for column in 6:
			var cell := Vector2i(column, row)
			var neighbours := Hex.neighbours(cell)
			if neighbours.size() != 6:
				neighbour_count_ok = false
			for neighbour in neighbours:
				if Hex.distance(cell, neighbour) != 1:
					all_adjacent = false
	check(neighbour_count_ok, "ogni cella ha sei vicini")
	check(all_adjacent, "ogni vicino dista un passo, su righe pari e dispari")

	# La vicinanza è reciproca: se A è vicino di B, B lo è di A. Una tabella di
	# scarti sbagliata rompe proprio questa simmetria, e il risolutore
	# costruirebbe percorsi a senso unico.
	var symmetric := true
	for row in 6:
		for column in 6:
			var cell := Vector2i(column, row)
			for neighbour in Hex.neighbours(cell):
				if not Hex.neighbours(neighbour).has(cell):
					symmetric = false
	check(symmetric, "la vicinanza è reciproca")

	# Andata e ritorno fra coordinate offset e cubiche.
	var round_trip := true
	for row in 8:
		for column in 8:
			var cell := Vector2i(column, row)
			if Hex.from_cube(Hex.to_cube(cell)) != cell:
				round_trip = false
	check(round_trip, "offset e cubiche si convertono senza perdite")

	# Le tre componenti cubiche sommano a zero: è l'invariante su cui poggia la
	# formula della distanza.
	var cube := Hex.to_cube(Vector2i(3, 5))
	check(cube.x + cube.y + cube.z == 0, "le coordinate cubiche sommano a zero", str(cube))

	# Distanza simmetrica e disuguaglianza triangolare su una coppia lontana.
	var a := Vector2i(0, 0)
	var b := Vector2i(4, 7)
	var middle := Vector2i(2, 3)
	check(Hex.distance(a, b) == Hex.distance(b, a), "la distanza è simmetrica")
	check(Hex.distance(a, b) <= Hex.distance(a, middle) + Hex.distance(middle, b),
		"vale la disuguaglianza triangolare")

	# Il campo è quello dichiarato dalle regole: 5 colonne per 4 righe a testa,
	# arena alta il doppio, panchina da 5, mai più di 6 unità schierate.
	var match_data: Dictionary = GameData.balance()["match"]
	check(int(match_data["board_columns"]) == 5 and int(match_data["board_rows"]) == 4,
		"il campo di un giocatore è 5 colonne per 4 righe")
	check(int(match_data["bench_size"]) == 5, "la panchina ha 5 posti")
	var per_level: Array = GameData.balance()["levels"]["units"]
	var most: int = 0
	for value in per_level:
		most = maxi(most, int(value))
	check(most == 6, "non si schierano mai più di 6 unità", str(per_level))


func _test_data_integrity() -> void:
	section("Integrità dei dati")

	var units := GameData.all_units()
	check(units.size() >= 18, "units.json contiene almeno 18 unità", str(units.size()))

	var known_origins := GameData.origin_ids()
	var known_classes := GameData.class_ids()
	var handled_abilities := [
		"shield_self", "buff_self", "damage_splash", "damage_line", "damage_nearest",
		"damage_over_time", "damage_execute", "stun_target", "heal_lowest_ally",
		"shield_allies", "rally",
	]

	var bad_origin := ""
	var bad_class := ""
	var bad_ability := ""
	var per_origin := {}
	for def in units:
		if not known_origins.has(def.origin):
			bad_origin = def.id
		per_origin[def.origin] = int(per_origin.get(def.origin, 0)) + 1
		for class_id in def.classes:
			if not known_classes.has(class_id):
				bad_class = "%s/%s" % [def.id, class_id]
		if not handled_abilities.has(def.ability_type()):
			bad_ability = "%s/%s" % [def.id, def.ability_type()]

	check(bad_origin == "", "ogni unità ha una civiltà nota", bad_origin)
	check(bad_class == "", "ogni classe è definita in traits.json", bad_class)
	check(bad_ability == "", "ogni abilità ha un tipo gestito dal risolutore", bad_ability)

	var thin_origin := ""
	for origin in known_origins:
		if int(per_origin.get(origin, 0)) < 6:
			thin_origin = origin
	check(thin_origin == "", "ogni civiltà ha almeno 6 unità (soglia massima raggiungibile)", thin_origin)

	# Le probabilità dello shop devono sommare a 1 a ogni livello.
	var bad_odds := ""
	for level in range(1, int(GameData.balance()["levels"]["max_level"]) + 1):
		var total := 0.0
		for value in GameData.shop_odds(level):
			total += float(value)
		if absf(total - 1.0) > 0.001:
			bad_odds = "livello %d somma %f" % [level, total]
	check(bad_odds == "", "le probabilità dello shop sommano a 1", bad_odds)

	# Una soglia che nessun roster può raggiungere è contenuto morto: capita
	# facilmente aggiungendo tratti prima delle unità che li portano.
	var unreachable: Array[String] = []
	var carriers := {}
	for def in units:
		for trait_id in def.traits():
			carriers[trait_id] = int(carriers.get(trait_id, 0)) + 1
	for trait_id in known_origins + known_classes:
		for tier in GameData.trait_def(trait_id).get("tiers", []):
			if int(tier["count"]) > int(carriers.get(trait_id, 0)):
				unreachable.append("%s %d" % [trait_id, int(tier["count"])])
	check(unreachable.is_empty(), "ogni soglia dei tratti è raggiungibile", ", ".join(unreachable))


func _test_rng_determinism() -> void:
	section("RNG")

	var a := SimRNG.new(12345)
	var b := SimRNG.new(12345)
	var same := true
	for i in 1000:
		if a.next_raw() != b.next_raw():
			same = false
			break
	check(same, "lo stesso seed produce lo stesso stream")

	var c := SimRNG.new(999)
	var in_range := true
	for i in 1000:
		var value := c.randi_range_ex(3, 7)
		if value < 3 or value >= 7:
			in_range = false
	check(in_range, "randi_range_ex resta nell'intervallo richiesto")

	# Distribuzione grossolana: con 4 esiti su 20000 tiri nessuno deve
	# scostarsi troppo dal 25%.
	var counts := {3: 0, 4: 0, 5: 0, 6: 0}
	var d := SimRNG.new(2024)
	for i in 20000:
		counts[d.randi_range_ex(3, 7)] += 1
	var balanced := true
	for key in counts:
		if absf(float(counts[key]) / 20000.0 - 0.25) > 0.02:
			balanced = false
	check(balanced, "la distribuzione è ragionevolmente uniforme", str(counts))


func _test_pool_conservation() -> void:
	section("Pool condiviso")

	var pool := UnitPool.new()
	var initial := _pool_total(pool)

	var rng := SimRNG.new(7)
	var player := Player.new(pool, rng)
	player.gold = 100
	player.refresh_shop(false)

	var bought := 0
	for i in 20:
		for slot in player.shop.size():
			if player.can_buy(slot) and player.buy(slot) != null:
				bought += 1
		player.refresh_shop()

	check(bought > 0, "il giocatore riesce a comprare dallo shop", str(bought))
	check(_pool_total(pool) + _owned_copies(player) + _shop_copies(player) == initial,
		"nessuna copia si perde tra pool, shop e squadra",
		"pool=%d owned=%d shop=%d initial=%d" % [_pool_total(pool), _owned_copies(player), _shop_copies(player), initial])

	# Vendere tutto deve riportare il pool al valore iniziale.
	for unit in player.units.duplicate():
		player.sell(unit)
	player.refresh_shop(true)
	for slot in player.shop.size():
		if player.shop[slot] != null:
			pool.give_back(player.shop[slot].id)
			player.shop[slot] = null
	check(_pool_total(pool) == initial, "vendere tutto restituisce ogni copia al pool",
		"%d vs %d" % [_pool_total(pool), initial])


func _pool_total(pool: UnitPool) -> int:
	var total := 0
	for count in pool.snapshot().values():
		total += int(count)
	return total


func _owned_copies(player: Player) -> int:
	var total := 0
	for unit in player.units:
		total += unit.copies_worth()
	return total


func _shop_copies(player: Player) -> int:
	var total := 0
	for offer in player.shop:
		if offer != null:
			total += 1
	return total


func _test_upgrade_cascade() -> void:
	section("Potenziamento a stelle")

	var pool := UnitPool.new()
	var player := Player.new(pool, SimRNG.new(1))

	for i in 2:
		player.grant_unit("legionarius")
	var two_stars := _count_at_star(player, "legionarius", 2)
	check(two_stars == 1 and player.units.size() == 1, "due copie diventano una 2★",
		"unità=%d" % player.units.size())

	for i in 2:
		player.grant_unit("legionarius")
	check(_count_at_star(player, "legionarius", 3) == 1, "quattro copie diventano una 3★",
		"unità=%d" % player.units.size())

	var three_star: UnitInstance = null
	for unit in player.units:
		if unit.star == 3:
			three_star = unit
	check(three_star != null and three_star.copies_worth() == 4,
		"una 3★ vale quattro copie quando torna nel pool")

	# La posizione va ereditata: se una copia era schierata, la 2★ resta in campo.
	var other := Player.new(pool, SimRNG.new(2))
	var first := other.grant_unit("clansman")
	other.move_to_board(first, Vector2i(3, 0))
	other.grant_unit("clansman")
	var upgraded: UnitInstance = other.units[0]
	check(other.units.size() == 1 and upgraded.is_on_board() and upgraded.cell == Vector2i(3, 0),
		"il potenziamento eredita la posizione in campo")


func _count_at_star(player: Player, unit_id: String, star: int) -> int:
	var count := 0
	for unit in player.units:
		if unit.def.id == unit_id and unit.star == star:
			count += 1
	return count


func _test_economy() -> void:
	section("Economia")

	var pool := UnitPool.new()
	var player := Player.new(pool, SimRNG.new(3))

	player.gold = 50
	var income := player.grant_round_income(true)
	check(int(income["interest"]) == 5, "gli interessi sono limitati a 5", str(income["interest"]))
	check(int(income["win_bonus"]) == 1, "la vittoria dà il bonus")
	check(player.gold == 50 + int(income["total"]), "l'oro cresce esattamente del totale calcolato")

	var streak_player := Player.new(pool, SimRNG.new(4))
	streak_player.gold = 0
	for i in 3:
		streak_player.grant_round_income(true)
	check(streak_player.streak == 3, "la serie di vittorie si accumula", str(streak_player.streak))
	var after_loss := streak_player.grant_round_income(false)
	check(streak_player.streak == -1, "una sconfitta azzera e inverte la serie", str(streak_player.streak))
	check(int(after_loss["win_bonus"]) == 0, "la sconfitta non dà bonus vittoria")

	var level_player := Player.new(pool, SimRNG.new(5))
	var start_level := level_player.level
	level_player.gold = 100
	for i in 10:
		level_player.buy_xp()
	check(level_player.level > start_level, "comprare esperienza fa salire di livello",
		"%d -> %d" % [start_level, level_player.level])
	check(level_player.max_board_units() == level_player.level,
		"le unità schierabili seguono il livello")


func _test_traits() -> void:
	section("Sinergie")

	var pool := UnitPool.new()
	var player := Player.new(pool, SimRNG.new(6))
	player.level = 6  # servono abbastanza slot per schierare tutta la formazione

	var roman_ids := ["legionarius", "sagittarius", "ballista", "equites"]
	var column := 0
	for unit_id in roman_ids:
		var unit := player.grant_unit(unit_id)
		player.move_to_board(unit, Vector2i(column, 0))
		column += 1

	var counts := TraitResolver.count_traits(player.board_units())
	check(int(counts.get("roman", 0)) == 4, "quattro unità distinte attivano Romani 4", str(counts))

	var tier := GameData.active_tier("roman", 4)
	check(int(tier.get("count", 0)) == 4, "viene scelta la soglia 4, non la 2")

	# Le copie non contano due volte.
	var duplicate := player.grant_unit("legionarius")
	player.move_to_board(duplicate, Vector2i(4, 1))
	check(int(TraitResolver.count_traits(player.board_units()).get("roman", 0)) == 4,
		"una copia della stessa unità non incrementa il tratto")

	var bonuses := TraitResolver.bonuses_by_uid(player.board_units())
	var archer: UnitInstance = null
	for unit in player.board_units():
		if unit.def.id == "sagittarius":
			archer = unit
	var archer_bonus: Dictionary = bonuses[archer.uid]
	check(float(archer_bonus.get("armor", 0.0)) >= 25.0,
		"il bonus romano (scope 'all') raggiunge anche l'arciere", str(archer_bonus))


func _test_combat_determinism() -> void:
	section("Combattimento")

	var first := _simulate_reference_battle(4242)
	var second := _simulate_reference_battle(4242)
	var different := _simulate_reference_battle(999)

	check(first["outcome"] == second["outcome"] and first["duration"] == second["duration"],
		"lo stesso seed produce lo stesso esito",
		"%s/%s vs %s/%s" % [first["outcome"], first["duration"], second["outcome"], second["duration"]])
	check(first["hash"] == second["hash"], "il log degli eventi è identico tick per tick")
	check(first["events"] > 10, "la battaglia genera eventi", str(first["events"]))
	check(first["duration"] < GameData.balance()["combat"]["max_duration_seconds"],
		"la battaglia si conclude prima del limite di tempo", str(first["duration"]))
	# Senza fonti di casualità (nessun critico attivo) la battaglia deve essere
	# identica a prescindere dal seed: è la prova che nulla nel risolutore
	# dipende da uno stato non controllato.
	check(different["hash"] == first["hash"],
		"senza tiri di dado l'esito non dipende dal seed")

	# Con i critici attivi, invece, il seed deve poter cambiare la battaglia.
	var crit_a := _simulate_crit_battle(1)
	var crit_b := _simulate_crit_battle(2)
	var crit_c := _simulate_crit_battle(3)
	check(crit_a["hash"] != crit_b["hash"] or crit_a["hash"] != crit_c["hash"],
		"con i critici attivi seed diversi producono battaglie diverse")

	# Una squadra molto più forte deve vincere: se questo test cade, il
	# risolutore sta ignorando stelle o statistiche.
	var strong_wins := 0
	for seed_value in range(10):
		var outcome := _simulate_asymmetric_battle(seed_value)
		if outcome == CombatSim.Outcome.TEAM_A:
			strong_wins += 1
	check(strong_wins == 10, "la squadra nettamente superiore vince sempre", "%d/10" % strong_wins)


func _simulate_reference_battle(battle_seed: int) -> Dictionary:
	var pool := UnitPool.new()
	var player_a := Player.new(pool, SimRNG.new(1))
	var player_b := Player.new(pool, SimRNG.new(2))

	_deploy(player_a, ["legionarius", "sagittarius", "equites", "ballista"], 0)
	_deploy(player_b, ["clansman", "gaul_hunter", "chariot", "gaul_druid"], 0)

	var sim := CombatSim.new(SimRNG.new(battle_seed))
	sim.setup(player_a.board_units(), player_b.board_units())
	var result := sim.run()

	# Riassume il log in un intero: due battaglie identiche devono avere lo
	# stesso valore, e qualunque divergenza lo cambia.
	var digest := 0
	for event in result["events"]:
		digest = (digest * 31 + hash(event)) & 0x7FFFFFFF

	return {
		"outcome": result["outcome"],
		"duration": result["duration"],
		"events": result["events"].size(),
		"hash": digest,
	}


## Schiera abbastanza arcieri da attivare la sinergia del critico: serve un
## risolutore che peschi davvero dal generatore.
func _simulate_crit_battle(battle_seed: int) -> Dictionary:
	var pool := UnitPool.new()
	var archers := Player.new(pool, SimRNG.new(20))
	var targets := Player.new(pool, SimRNG.new(21))

	_deploy(archers, ["sagittarius", "gaul_hunter", "teuton_skirmisher", "gaul_slinger"], 3)
	_deploy(targets, ["legionarius", "shieldmaiden", "teuton_spearman"], 0)

	var sim := CombatSim.new(SimRNG.new(battle_seed))
	sim.setup(archers.board_units(), targets.board_units())
	var result := sim.run()

	var digest := 0
	for event in result["events"]:
		digest = (digest * 31 + hash(event)) & 0x7FFFFFFF
	return {"outcome": result["outcome"], "hash": digest}


func _simulate_asymmetric_battle(battle_seed: int) -> int:
	var pool := UnitPool.new()
	var strong := Player.new(pool, SimRNG.new(10))
	var weak := Player.new(pool, SimRNG.new(11))

	strong.level = 6
	for i in 4:
		var unit := strong.grant_unit("caesar", 3)
		strong.move_to_board(unit, Vector2i(i + 1, 1))
	weak.level = 6
	for i in 4:
		var unit := weak.grant_unit("teuton_skirmisher", 1)
		weak.move_to_board(unit, Vector2i(i + 1, 1))

	var sim := CombatSim.new(SimRNG.new(battle_seed))
	sim.setup(strong.board_units(), weak.board_units())
	return sim.run()["outcome"]


func _deploy(player: Player, unit_ids: Array, row: int) -> void:
	player.level = 6
	var column := 1
	for unit_id in unit_ids:
		var unit := player.grant_unit(unit_id)
		player.move_to_board(unit, Vector2i(column, row))
		column += 1


func _test_full_match() -> void:
	section("Partita completa")

	var match_state := MatchState.new(20260817, 0)
	var brains: Array[BotBrain] = []
	var brain_rng := SimRNG.new(77)
	for player in match_state.players:
		brains.append(BotBrain.new(player, brain_rng.fork(player.index)))

	var rounds := 0
	while match_state.phase != MatchState.Phase.FINISHED and rounds < 200:
		match_state.start_round()
		for brain in brains:
			brain.play_preparation(match_state.stage)
		match_state.resolve_round()
		rounds += 1

	check(match_state.phase == MatchState.Phase.FINISHED,
		"la partita termina da sola", "round giocati: %d" % rounds)
	check(rounds < 200, "termina in un numero ragionevole di round", str(rounds))

	var standings := match_state.standings()
	check(standings[0].placement == 1, "esiste un vincitore", standings[0].display_name)

	var placements := {}
	var duplicated := false
	for player in standings:
		if placements.has(player.placement):
			duplicated = true
		placements[player.placement] = true
	check(not duplicated, "le posizioni finali sono tutte distinte", str(placements.keys()))

	var max_level := 0
	var max_units := 0
	for player in match_state.players:
		max_level = maxi(max_level, player.level)
		max_units = maxi(max_units, player.units.size())
	check(max_level >= 5, "i bot progrediscono di livello", "livello massimo %d" % max_level)
	check(max_units >= 5, "i bot accumulano unità", "unità massime %d" % max_units)

	print("  (vincitore: %s, round: %d, livello max: %d)" % [standings[0].display_name, rounds, max_level])


func _test_monetization() -> void:
	section("Monetizzazione")

	Catalog.ensure_loaded()

	# Ogni entitlement deve avere un prodotto per ognuna delle piattaforme di
	# pubblicazione: un entitlement senza prodotto è invendibile e se ne
	# accorgerebbe solo un giocatore davanti a un pulsante che non fa nulla.
	var missing: Array[String] = []
	for entitlement_id in Catalog.entitlement_ids():
		for platform in ["android", "web"]:
			if Catalog.product_id(entitlement_id, platform).is_empty():
				missing.append("%s/%s" % [entitlement_id, platform])
	check(missing.is_empty(), "ogni entitlement ha un prodotto per ogni piattaforma", ", ".join(missing))

	# Ogni civiltà è gratuita oppure ha un entitlement che la sblocca: una
	# civiltà né gratuita né acquistabile sarebbe irraggiungibile.
	var unreachable: Array[String] = []
	for origin_id in GameData.origin_ids():
		var free := Catalog.free_origins().has(String(origin_id))
		if not free and Catalog.entitlement_for_origin(String(origin_id)).is_empty():
			unreachable.append(String(origin_id))
	check(unreachable.is_empty(), "ogni civiltà è gratuita o acquistabile", ", ".join(unreachable))
	check(not Catalog.free_origins().is_empty(), "almeno una civiltà è gratuita")

	# La chiave segreta di RevenueCat non deve MAI stare nel client: qui si
	# controlla che nessuno l'abbia incollata per comodità.
	var catalog_text := FileAccess.get_file_as_string(Catalog.PATH)
	check(not catalog_text.contains("sk_"), "nessuna chiave segreta nel catalogo")

	# Flusso completo sul negozio finto.
	var store := MockStore.new()
	store.clear()
	check(store.active_entitlements().is_empty(), "si parte senza acquisti")

	var completed := {"id": "", "ok": false}
	store.purchase_completed.connect(func(id: String, ok: bool, _reason: String) -> void:
		completed["id"] = id
		completed["ok"] = ok)
	store.purchase("civ_gaul")
	check(completed["id"] == "civ_gaul" and completed["ok"], "l'acquisto emette l'esito")
	check(store.active_entitlements().has("civ_gaul"), "l'entitlement risulta posseduto")

	# Il ripristino deve ritrovare ciò che era stato comprato: è il requisito
	# di Google Play che si dimentica più spesso.
	var reloaded := MockStore.new()
	reloaded.initialize("", "test")
	check(reloaded.active_entitlements().has("civ_gaul"), "gli acquisti sopravvivono al riavvio")

	store.purchase("prodotto_inesistente")
	check(not completed["ok"], "un entitlement sconosciuto non viene concesso")
	store.clear()

	# I backend reali non devono attivarsi su desktop.
	check(not RevenueCatAndroid.new().is_available(), "il backend Android non si attiva su desktop")
	check(not RevenueCatWeb.new().is_available(), "il backend web non si attiva su desktop")


func _test_replay_log() -> void:
	section("Log di riproduzione")

	var pool := UnitPool.new()
	var player_a := Player.new(pool, SimRNG.new(30))
	var player_b := Player.new(pool, SimRNG.new(31))
	_deploy(player_a, ["legionarius", "sagittarius", "vestal", "equites"], 0)
	_deploy(player_b, ["clansman", "gaul_hunter", "gaul_druid", "chariot"], 0)

	var sim := CombatSim.new(SimRNG.new(555))
	sim.setup(player_a.board_units(), player_b.board_units())
	var combat := sim.run()

	var initial: Array = combat["initial"]
	check(initial.size() == 8, "lo schieramento iniziale è completo", str(initial.size()))

	var missing_fields: Array[String] = []
	for entry in initial:
		for field in ["uid", "name", "origin", "star", "team", "cell", "max_hp"]:
			if not entry.has(field):
				missing_fields.append(field)
	check(missing_fields.is_empty(), "ogni unità porta i dati necessari a disegnarla",
		", ".join(missing_fields))

	# Ricostruisce lo stato finale rigiocando SOLO il log: è esattamente ciò
	# che fa la vista di combattimento, e ciò che farà un client online.
	var hp := {}
	var alive := {}
	var cells := {}
	for entry in initial:
		hp[int(entry["uid"])] = float(entry["max_hp"])
		alive[int(entry["uid"])] = true
		cells[int(entry["uid"])] = entry["cell"]

	var unknown_uid := false
	var out_of_order := false
	var previous_time := -1.0
	for event in combat["events"]:
		if float(event["t"]) < previous_time:
			out_of_order = true
		previous_time = float(event["t"])

		var uid := int(event.get("uid", -1))
		if uid != -1 and not hp.has(uid):
			unknown_uid = true
			continue
		match String(event["type"]):
			"damage", "heal", "periodic":
				hp[uid] = float(event["hp"])
			"death":
				alive[uid] = false
				hp[uid] = 0.0
			"move":
				cells[uid] = event["to"]

	check(not out_of_order, "gli eventi sono in ordine di tempo")
	check(not unknown_uid, "ogni evento si riferisce a un'unità dello schieramento")

	# Chi il log dice vivo deve coincidere con i sopravvissuti veri, e con la
	# salute giusta: se diverge, il replay mostrerebbe una battaglia diversa
	# da quella che ha deciso il round.
	var mismatched: Array[String] = []
	for unit in sim.units:
		var replay_alive := bool(alive[unit.uid])
		if replay_alive != unit.is_alive():
			mismatched.append("%s vivo=%s replay=%s" % [unit.def.display_name, unit.is_alive(), replay_alive])
		elif unit.is_alive() and absf(float(hp[unit.uid]) - unit.hp) > 0.01:
			mismatched.append("%s hp=%.1f replay=%.1f" % [unit.def.display_name, unit.hp, hp[unit.uid]])
	check(mismatched.is_empty(), "rigiocando il log si ottiene lo stato finale esatto",
		"; ".join(mismatched))

	var positions_ok := true
	for unit in sim.units:
		if unit.is_alive() and cells[unit.uid] != unit.cell:
			positions_ok = false
	check(positions_ok, "rigiocando il log le unità finiscono nelle celle giuste")
