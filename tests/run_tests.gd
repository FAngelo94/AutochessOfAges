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
	_test_tutorial_data()
	_test_hex_grid()
	_test_rng_determinism()
	_test_pool_conservation()
	_test_upgrade_cascade()
	_test_heroes()
	_test_economy()
	_test_combat_determinism()
	_test_traits()
	_test_full_match()
	_test_live_ranking()
	_test_eliminated_cannot_shop()
	_test_rematch_avoidance()
	_test_ghost_uses_eliminated_formation()
	_test_spectate_ghost_matchup()
	_test_replay_log()
	_test_monetization()
	_test_serialization_roundtrip()
	_test_view_filtering()

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

	var heroes := GameData.all_heroes()
	check(heroes.size() >= 2, "heroes.json contiene almeno 2 eroi", str(heroes.size()))

	var unit_ids := {}
	for def in units:
		unit_ids[def.id] = true
	var colliding_hero := ""
	var bad_hero_origin := ""
	for hdef in heroes:
		if unit_ids.has(hdef.id):
			colliding_hero = hdef.id
		if not known_origins.has(hdef.origin):
			bad_hero_origin = hdef.id
	check(colliding_hero == "", "nessun id eroe coincide con un id unità", colliding_hero)
	check(bad_hero_origin == "", "ogni eroe ha una civiltà nota (per la palette del modello)", bad_hero_origin)


## Verifica solo i dati (data/tutorial.json), senza costruire nessuna UI: la
## guida e le bolle vengono provate con lo schermo vero in menu_smoke.gd e
## ui_smoke.gd, qui si controlla solo che il contenuto sia coerente.
func _test_tutorial_data() -> void:
	section("Dati del tutorial")

	var tutorial := GameData.tutorial()
	check(tutorial.has("guide") and tutorial.has("tips"),
		"tutorial.json ha sia 'guide' sia 'tips'")

	var sections: Array = GameData.guide_sections()
	check(not sections.is_empty(), "la guida ha almeno un capitolo")

	var bad_section := ""
	var seen_ids := {}
	var duplicate_id := ""
	for entry in sections:
		var id := String(entry.get("id", ""))
		var title := String(entry.get("title", ""))
		var body := String(entry.get("body", ""))
		if id.is_empty() or title.is_empty() or body.is_empty():
			bad_section = id if not id.is_empty() else title
		if seen_ids.has(id):
			duplicate_id = id
		seen_ids[id] = true
	check(bad_section == "", "ogni capitolo ha id, titolo e corpo non vuoti", bad_section)
	check(duplicate_id == "", "gli id dei capitoli sono unici", duplicate_id)

	# Ogni id usato dal codice deve avere una voce nel JSON: altrimenti
	# TipBubble.queue_tip scarta silenziosamente il suggerimento (push_error
	# a parte) e la bolla non compare mai.
	var missing_tip := ""
	for tip_id in TipBubble.KNOWN_TIPS:
		if GameData.tip(tip_id).is_empty():
			missing_tip = tip_id
	check(missing_tip == "", "ogni id noto a TipBubble esiste in tutorial.json", missing_tip)

	for tip_id in GameData.tutorial().get("tips", {}).keys():
		var entry: Dictionary = GameData.tip(tip_id)
		var ok := not String(entry.get("title", "")).is_empty() and not String(entry.get("body", "")).is_empty()
		check(ok, "il suggerimento '%s' ha titolo e corpo non vuoti" % tip_id)

	# Ogni segnaposto {chiave} nei testi deve corrispondere a una chiave che
	# TutorialText.expand sa risolvere: altrimenti resterebbe "{chiave}"
	# letterale a schermo.
	var known_placeholders := ["players", "interest_per", "max_interest", "reroll_cost", "buy_xp_cost"]
	var all_texts: Array[String] = []
	for entry in sections:
		all_texts.append(String(entry.get("body", "")))
	for tip_id in GameData.tutorial().get("tips", {}).keys():
		all_texts.append(String(GameData.tip(tip_id).get("body", "")))

	var regex := RegEx.new()
	regex.compile("\\{(\\w+)\\}")
	var unknown_placeholder := ""
	var unresolved_after_expand := ""
	for text in all_texts:
		for m in regex.search_all(text):
			var placeholder := m.get_string(1)
			if not known_placeholders.has(placeholder):
				unknown_placeholder = placeholder
		if "{" in TutorialText.expand(text):
			unresolved_after_expand = text
	check(unknown_placeholder == "", "ogni segnaposto usato è risolvibile da TutorialText", unknown_placeholder)
	check(unresolved_after_expand == "", "TutorialText.expand risolve tutti i segnaposto presenti", unresolved_after_expand)


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


func _test_heroes() -> void:
	section("Eroi")

	var pool := UnitPool.new()

	# Cesare: 3-6 oro casuali a ogni sconfitta, sempre nel range, riproducibile
	# a parità di seed. È l'unica fonte di casualità nuova aggiunta dagli eroi,
	# quindi va verificata contro il rischio più grave del progetto: se non
	# passasse dallo SimRNG del player, romperebbe il determinismo.
	var cesare := Player.new(pool, SimRNG.new(42))
	cesare.hero_id = "cesare"
	var bonuses: Array[int] = []
	for i in 200:
		var income := cesare.grant_round_income(false)
		bonuses.append(int(income["hero_bonus"]))
	var out_of_range := bonuses.filter(func(b: int) -> bool: return b < 3 or b > 6)
	check(out_of_range.is_empty(), "il bonus di Cesare resta sempre tra 3 e 6",
		str(out_of_range))

	var cesare_repeat := Player.new(pool, SimRNG.new(42))
	cesare_repeat.hero_id = "cesare"
	var repeated: Array[int] = []
	for i in 200:
		repeated.append(int(cesare_repeat.grant_round_income(false)["hero_bonus"]))
	check(bonuses == repeated, "il bonus di Cesare è riproducibile a parità di seed")

	var no_hero := Player.new(pool, SimRNG.new(7))
	check(int(no_hero.grant_round_income(false)["hero_bonus"]) == 0,
		"senza eroe selezionato non c'è alcun bonus")

	# Vercingetorige: 1 oro per ogni evento di fusione. Comprando quattro copie
	# una alla volta si fondono le prime due in una 2★, le altre due in
	# un'altra 2★, e infine le due 2★ in una 3★: tre fusioni in tutto (lo
	# stesso conteggio verificato da "quattro copie diventano una 3★" sopra).
	var vercingetorige := Player.new(pool, SimRNG.new(9))
	vercingetorige.hero_id = "vercingetorige"
	vercingetorige.gold = 0
	for i in 4:
		vercingetorige.grant_unit("legionarius")
	check(vercingetorige.gold == 3, "Vercingetorige guadagna 1 oro per ognuna delle tre fusioni della catena",
		str(vercingetorige.gold))

	# Bot: l'eroe assegnato deve essere valido e deterministico a parità di seed.
	var seed_value := 4242
	var match_a := MatchState.new(seed_value, 1)
	var brain_rng_a := SimRNG.new(match_a.seed_value ^ 0x5EED)
	var bot_heroes_a: Array[String] = []
	for p in match_a.players:
		if p.is_bot:
			BotBrain.new(p, brain_rng_a.fork(p.index))
			bot_heroes_a.append(p.hero_id)

	var match_b := MatchState.new(seed_value, 1)
	var brain_rng_b := SimRNG.new(match_b.seed_value ^ 0x5EED)
	var bot_heroes_b: Array[String] = []
	for p in match_b.players:
		if p.is_bot:
			BotBrain.new(p, brain_rng_b.fork(p.index))
			bot_heroes_b.append(p.hero_id)

	var invalid_bot_hero := ""
	for hero_id in bot_heroes_a:
		if not GameData.has_hero(hero_id):
			invalid_bot_hero = hero_id
	check(invalid_bot_hero == "", "ogni bot riceve un eroe valido", invalid_bot_hero)
	check(bot_heroes_a == bot_heroes_b,
		"a parità di seed i bot ricevono sempre gli stessi eroi")


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

	var roman_ids := ["legionarius", "sagittarius", "ballistarius", "equites"]
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

	_deploy(player_a, ["legionarius", "sagittarius", "equites", "ballistarius"], 0)
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
		var unit := strong.grant_unit("cataphractus", 3)
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


## La classifica dal vivo: vita decrescente e, a parità, davanti chi l'ha persa
## più tardi. È l'ordine che vedono sia le card degli avversari sia la schermata
## di chi è eliminato, quindi una regressione qui si vede in due posti.
func _test_live_ranking() -> void:
	section("Classifica dal vivo")

	var ms := MatchState.new(4242, 0)
	var a: Player = ms.players[0]
	var b: Player = ms.players[1]
	var c: Player = ms.players[2]

	# Stessa vita, ma b la perde DOPO a: b sta davanti.
	a.take_damage(10, ms.next_damage_stamp())
	b.take_damage(10, ms.next_damage_stamp())
	check(MatchState.ranks_before(b, a),
		"a parità di vita sta davanti chi l'ha persa più tardi")
	check(not MatchState.ranks_before(a, b), "e la relazione non è simmetrica")

	# La vita batte il timbro: c non è mai stato colpito, quindi sta davanti a
	# entrambi anche se il suo timbro è 0.
	check(MatchState.ranks_before(c, b), "più vita batte un timbro più recente")

	var ranking := ms.live_ranking()
	check(ranking.size() == ms.players.size(), "la classifica contiene tutti i giocatori")
	check(ranking[ranking.size() - 1] == a, "l'ultimo è chi ha meno vita e il timbro più vecchio",
		ranking[ranking.size() - 1].display_name)

	# rank_of() conta invece di cercare: deve comunque dare la stessa posizione.
	var consistent := true
	for i in ranking.size():
		if ms.rank_of(ranking[i]) != i + 1:
			consistent = false
	check(consistent, "rank_of() concorda con l'ordine di live_ranking()")

	# Morti nello stesso round: il piazzamento segue l'ordine temporale, non
	# quello degli indici. Prima era l'indice del posto — arbitrario.
	var ms2 := MatchState.new(99, 0)
	var early: Player = ms2.players[5]   # indice ALTO, muore per PRIMO
	var late: Player = ms2.players[1]    # indice BASSO, muore per SECONDO
	early.take_damage(early.hp, ms2.next_damage_stamp())
	late.take_damage(late.hp, ms2.next_damage_stamp())
	ms2._apply_eliminations()
	check(late.placement < early.placement,
		"fra due morti nello stesso round è piazzato meglio chi è morto dopo",
		"morto dopo %d°, morto prima %d°" % [late.placement, early.placement])

	# Se muoiono tutti insieme, qualcuno deve comunque risultare primo:
	# _next_placement parte dal numero di giocatori e scende, quindi l'ultimo
	# eliminato prende 1 anche senza sopravvissuti.
	var ms3 := MatchState.new(7, 0)
	for p in ms3.players:
		p.take_damage(p.hp, ms3.next_damage_stamp())
	ms3._apply_eliminations()
	var winners := 0
	for p in ms3.players:
		if p.placement == 1:
			winners += 1
	check(winners == 1, "anche senza sopravvissuti esiste un solo primo posto", str(winners))


## Il pool è condiviso: un eliminato che continua a comprare toglie copie ai
## vivi. Il divieto sta in core/, così vale identico offline e online.
func _test_eliminated_cannot_shop() -> void:
	section("Eliminato: niente negozio")

	var ms := MatchState.new(31337, 0)
	var p: Player = ms.players[0]
	p.gold = 99
	check(p.can_reroll(), "da vivo si può aggiornare il negozio")

	var pool_before := ms.pool.snapshot()
	p.take_damage(p.hp, ms.next_damage_stamp())
	check(not p.is_alive(), "il giocatore è eliminato")

	check(not p.can_reroll(), "da eliminato non si aggiorna il negozio")
	check(not p.reroll(), "e reroll() rifiuta")
	check(not p.buy_xp(), "da eliminato non si compra esperienza")
	var can_buy_any := false
	for slot in p.shop.size():
		if p.can_buy(slot):
			can_buy_any = true
	check(not can_buy_any, "da eliminato nessuno slot del negozio è acquistabile")
	check(p.gold == 99, "e l'oro non è stato speso", str(p.gold))
	check(ms.pool.snapshot() == pool_before,
		"il pool condiviso non è stato toccato")


## A7 — build_matchups() evita di riproporre gli avversari degli ultimi round.
func _test_rematch_avoidance() -> void:
	section("Accoppiamenti — niente rivincite ravvicinate")

	# Tutti e 8 vivi (nessun resolve_round): si osservano solo gli accoppiamenti.
	var immediate := 0
	var total := 0
	for s in [11, 22, 33, 44, 55, 66, 77, 88]:
		var ms := MatchState.new(s, 0)
		var prev := {}
		for _r in 6:
			var cur := {}
			for m in ms.build_matchups():
				if m["b"] == null:
					continue
				cur[m["a"].index] = m["b"].index
				cur[m["b"].index] = m["a"].index
			for idx in cur:
				total += 1
				if prev.get(idx, -1) == cur[idx]:
					immediate += 1
			prev = cur
	# L'accoppiamento adiacente casuale darebbe ~1/7 (~14%); con la finestra
	# la rivincita col round precedente deve essere rara.
	check(immediate <= total / 20,
		"le rivincite col round precedente sono rare (%d su %d)" % [immediate, total])

	# Riproducibilità: stesso seed -> stessa sequenza di accoppiamenti.
	var run_a := _matchup_trace(4242)
	var run_b := _matchup_trace(4242)
	check(run_a == run_b, "gli accoppiamenti sono riproducibili a parità di seed")


func _matchup_trace(seed_value: int) -> Array:
	var ms := MatchState.new(seed_value, 0)
	var trace: Array = []
	for _r in 5:
		var round_pairs: Array = []
		for m in ms.build_matchups():
			var b_idx: int = (m["b"].index if m["b"] != null else -1)
			round_pairs.append([m["a"].index, b_idx, m["ghost"]])
		trace.append(round_pairs)
	return trace


## A7b — con un numero dispari di vivi lo spaiato affronta il fantasma di un
## eliminato (il suo ultimo schieramento), non la copia di un vivo.
func _test_ghost_uses_eliminated_formation() -> void:
	section("Accoppiamenti — il fantasma è un eliminato")

	var ms := MatchState.new(9182, 0)

	# Tre eliminati con una board congelata, cinque vivi -> conta dispari.
	var dead_indices := {}
	for i in 3:
		var victim: Player = ms.players[i]
		var unit := victim.grant_unit("legionarius")
		victim.move_to_board(unit, Vector2i(0, 0))
		victim.take_damage(victim.hp, ms.next_damage_stamp())
		check(not victim.is_alive(), "il giocatore %d è eliminato" % i)
		check(not victim.board_units().is_empty(), "e conserva il suo schieramento")
		dead_indices[i] = true

	check(ms.alive_players().size() == 5, "cinque vivi rimasti")

	var ghost_count := 0
	var normal_count := 0
	for m in ms.build_matchups():
		if m["ghost"]:
			ghost_count += 1
			check(m["b"] != null, "il fantasma ha un avversario")
			check(dead_indices.has(m["b"].index),
				"l'avversario fantasma è un eliminato (indice %d)" % m["b"].index)
			check(m["b"].index != m["a"].index, "e non è lo spaiato stesso")
		else:
			normal_count += 1
			check(m["a"].is_alive() and m["b"].is_alive(),
				"gli scontri normali sono fra vivi")

	check(ghost_count == 1, "esattamente un fantasma")
	check(normal_count == 2, "e due scontri normali")


## Lo scontro contro il fantasma di un eliminato è rivedibile dalla schermata
## classifica sia cliccando il vivo che ha combattuto sia cliccando l'eliminato
## di cui è stato usato lo schieramento — stesso replay, lato opposto.
func _test_spectate_ghost_matchup() -> void:
	section("Spettatore — il replay contro un fantasma è rivedibile da entrambi i lati")

	var session := LocalSession.new()
	session.begin(5150)
	var ms := session.state()

	# Tre bot eliminati con una board congelata -> cinque vivi (dispari).
	for i in [3, 4, 5]:
		var victim: Player = ms.players[i]
		victim.move_to_board(victim.grant_unit("legionarius"), Vector2i(0, 0))
		victim.take_damage(victim.hp, ms.next_damage_stamp())
	for p in ms.alive_players():
		if p.board_units().is_empty():
			p.move_to_board(p.grant_unit("legionarius"), Vector2i(0, 0))

	var events: Array = []
	session.spectate_ready.connect(func(idx, combat, team, _hero):
		events.append({"idx": idx, "combat": combat, "team": team}))

	session.request_ready()  # risolve il round

	var ghost_row := {}
	for row in ms.last_results():
		if bool(row.get("ghost", false)) and row.get("opponent") != null:
			ghost_row = row
			break
	check(not ghost_row.is_empty(), "il round ha prodotto un matchup fantasma")

	var live_idx: int = ghost_row["player"].index
	var dead_idx: int = ghost_row["opponent"].index
	check(not ms.players[dead_idx].is_alive(), "l'avversario fantasma è un eliminato")

	check(session.can_spectate(live_idx), "si può rivedere dal lato del vivo")
	check(session.can_spectate(dead_idx), "e dal lato dell'eliminato")

	session.request_spectate(live_idx)
	session.request_spectate(dead_idx)
	check(events.size() == 2, "due spectate_ready emessi", str(events.size()))
	check(events.size() == 2 and not events[0]["combat"].is_empty() \
		and not events[1]["combat"].is_empty(), "entrambi portano il log di combattimento")
	check(events.size() == 2 and events[0]["team"] != events[1]["team"],
		"i due lati dell'arena sono opposti")

	var other_dead := -1
	for i in [3, 4, 5]:
		if i != dead_idx and ms.players[i].placement > 0:
			other_dead = i
			break
	check(other_dead != -1 and not session.can_spectate(other_dead),
		"un eliminato non 'fantasmato' resta non rivedibile")


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


## MatchState -> to_dict -> var_to_bytes -> bytes_to_var -> apply_dict su una
## istanza vuota, e lo stato ricostruito coincide campo per campo. È il
## prerequisito del multiplayer autoritativo: il client rigioca gli snapshot.
func _test_serialization_roundtrip() -> void:
	section("Serializzazione")

	var original := MatchState.new(20260827, 1)
	var brains: Array[BotBrain] = []
	var brain_rng := SimRNG.new(original.seed_value ^ 0x5EED)
	for player in original.players:
		brains.append(BotBrain.new(player, brain_rng.fork(player.index)))
	for r in 3:
		original.start_round()
		for brain in brains:
			brain.play_preparation(original.stage)
		original.resolve_round()

	var for_index := 0
	var bytes := var_to_bytes(original.to_dict(for_index))
	var decoded: Dictionary = bytes_to_var(bytes)
	check(decoded is Dictionary and not decoded.is_empty(), "il dizionario sopravvive a var_to_bytes/bytes_to_var")

	var rebuilt := MatchState.new(1, 1)
	rebuilt.apply_dict(decoded)

	check(rebuilt.phase == original.phase, "fase ricostruita", "%d vs %d" % [rebuilt.phase, original.phase])
	check(rebuilt.stage == original.stage, "stage ricostruito")
	check(rebuilt.round_index == original.round_index, "round_index ricostruito")
	check(rebuilt.seed_value == original.seed_value, "seed_value ricostruito")
	check(rebuilt.pool.snapshot() == original.pool.snapshot(), "snapshot del pool identico")

	var fields_ok := true
	var units_ok := true
	for i in original.players.size():
		var o: Player = original.players[i]
		var b: Player = rebuilt.players[i]
		# last_damage_stamp deve attraversare il filo: se non lo facesse, la
		# classifica del client si scorderebbe l'ordine temporale e mostrerebbe
		# un ordine diverso da quello del server.
		if o.hp != b.hp or o.level != b.level or o.placement != b.placement \
				or o.streak != b.streak or o.last_damage_stamp != b.last_damage_stamp:
			fields_ok = false
		var expected: Array = o.units if i == for_index else o.board_units()
		if b.units.size() != expected.size():
			units_ok = false
			continue
		for ou in expected:
			var bu: UnitInstance = b.unit_by_uid(ou.uid)
			if bu == null or bu.star != ou.star or bu.cell != ou.cell or bu.def.id != ou.def.id \
					or bu.bench_slot != ou.bench_slot:
				units_ok = false
	check(fields_ok, "hp, livello, piazzamento e serie ricostruiti per ogni giocatore")
	check(units_ok, "ogni unità ricostruita con uid, stella, cella e slot di panchina")

	# Regressione: senza bench_slot sul filo la panchina tornava tutta a slot -1 e
	# ui/main.gd:_refresh_bench (che indicizza per slot) disegnava caselle vuote pur
	# avendo le unità nello stato — le unità comprate "sparivano" dalla panchina.
	var origin_bench: Array = original.players[for_index].bench_units()
	var rebuilt_bench: Array = rebuilt.players[for_index].bench_units()
	var slots_ok := not origin_bench.is_empty() and origin_bench.size() == rebuilt_bench.size()
	var by_slot := {}
	for u in rebuilt_bench:
		by_slot[u.bench_slot] = u
	for ou in origin_bench:
		var bu: UnitInstance = by_slot.get(ou.bench_slot)
		if bu == null or bu.uid != ou.uid:
			slots_ok = false
	check(slots_ok, "la panchina è indirizzabile per slot dopo il round-trip",
		"%d unità in panchina" % origin_bench.size())
	check(rebuilt.players[for_index].gold == original.players[for_index].gold, "l'oro del ricevente è ricostruito")
	check(rebuilt.players[for_index].xp == original.players[for_index].xp, "l'esperienza del ricevente è ricostruita")


## Test anti-cheat: il dict di un giocatore visto da un ALTRO giocatore non
## contiene shop, gold, xp, panchina. Mai sul filo lo stato privato altrui.
func _test_view_filtering() -> void:
	section("Filtro delle viste (anti-cheat)")

	var ms := MatchState.new(555, 1)
	var mine := ms.players[0].to_dict(true)
	var d := ms.players[0].to_dict(false)

	check(mine.has("shop") and mine.has("gold") and mine.has("bench"),
		"il giocatore vede il proprio shop, oro e panchina")
	check(not d.has("shop"), "un avversario non vede lo shop")
	check(not d.has("gold"), "un avversario non vede l'oro")
	check(not d.has("xp"), "un avversario non vede l'esperienza")
	check(not d.has("bench"), "un avversario non vede la panchina")
	check(d.has("board"), "un avversario vede comunque il tavolo")
	# Pubblico di proposito: senza, ogni client ordinerebbe la classifica a modo
	# suo. È un numero d'ordine, non un'informazione di gioco.
	check(d.has("last_damage_stamp"), "il timbro dell'ultimo danno è pubblico")


func _test_replay_log() -> void:
	section("Log di riproduzione")

	var pool := UnitPool.new()
	var player_a := Player.new(pool, SimRNG.new(30))
	var player_b := Player.new(pool, SimRNG.new(31))
	_deploy(player_a, ["legionarius", "sagittarius", "velites", "equites"], 0)
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
