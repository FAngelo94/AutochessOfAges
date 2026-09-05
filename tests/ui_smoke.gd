extends SceneTree

## Smoke test dell'interfaccia:
##
##   godot --headless --path . --script res://tests/ui_smoke.gd
##
## Istanzia la scena di gioco e la pilota come farebbe un giocatore: compra,
## schiera, sposta, vende e gioca la partita fino in fondo. Non verifica
## l'aspetto grafico, ma coglie ciò che rompe più spesso — un nodo rinominato,
## un segnale scollegato, un indice fuori dai limiti in un refresh.
##
## Il seed va fissato, altrimenti ogni esecuzione compra unità diverse e il
## test fallisce a intermittenza:
##
##   godot --headless --path . --script res://tests/ui_smoke.gd -- --seed=4242

var _passed := 0
var _failed := 0
var _frames := 0
var _main: Control = null


## In uno script SceneTree personalizzato, _initialize() viene eseguito prima
## che autoload e scena principale siano pronti: un nodo aggiunto qui non ha
## ancora ricevuto _ready(). Perciò si istanzia al primo frame e si prova al
## secondo, quando l'albero è vivo davvero.
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		var scene: PackedScene = load("res://ui/main.tscn")
		_main = scene.instantiate()
		root.add_child(_main)
		return false
	if _frames == 2:
		_run(_main)
	return false


func _run(main: Control) -> void:
	# Il test gioca partite intere, che finirebbero nelle statistiche del
	# profilo: si annota lo stato e si rimette a posto alla fine.
	var profile := main.get_node("/root/Profile")
	var saved_matches: int = profile.matches_played
	var saved_best: int = profile.best_placement
	# .duplicate(): PackedStringArray non fa copy-on-write in GDScript, una
	# semplice assegnazione condividerebbe il buffer con profile.seen_tips.
	var saved_tips: PackedStringArray = profile.seen_tips.duplicate()

	check(main.match_state != null, "la partita viene creata all'avvio")
	# Stessa cura del profilo per la cronologia locale: il test gioca una
	# partita vera e la scrive in user://history.json, che e' quella di chi
	# sviluppa. Si annota e si rimette com'era in fondo.
	var saved_history := MatchLog.local_matches()
	var history_before := saved_history.size()
	# La telemetria di bilanciamento va rimessa a posto tale e quale: qui le
	# scelte le fa il test, non un giocatore, e quei numeri falserebbero il
	# report di tools/unit_balance.gd.
	var saved_telemetry := _read_text(MatchLog.TELEMETRY_PATH)

	# Il suggerimento del negozio compare da solo alla prima partita; una volta
	# verificato, si disattivano le bolle per il resto del test — qui si pilota
	# l'interfaccia come chi ha fretta, e le bolle interferirebbero con quel
	# percorso senza aggiungere altra copertura.
	check(main._tips.is_showing(), "il suggerimento del negozio compare all'avvio")
	main._tips.dismiss()
	check(profile.has_seen_tip("shop"), "chiudere il suggerimento lo marca come visto")
	main._tips.enabled = false
	check(main.player() != null and not main.player().is_bot, "esiste un giocatore umano")
	check(main.player().hero_id != "" and GameData.has_hero(main.player().hero_id),
		"il giocatore umano ha sempre un eroe valido (selezione obbligatoria)",
		main.player().hero_id)

	var player: Player = main.player()
	player.gold = 100

	# Compra tutto il comprabile e schiera ogni unità: il percorso più
	# battuto dell'interfaccia.
	var bought := 0
	for slot in player.shop.size():
		if player.can_buy(slot):
			main._on_shop_slot_pressed(slot)
			bought += 1
	check(bought > 0, "si riesce a comprare dal negozio", str(bought))

	var bench := player.bench_units()
	check(not bench.is_empty(), "le unità comprate finiscono in panchina")

	# Selezione dalla panchina, poi piazzamento su una cella.
	main._on_bench_slot_pressed(bench[0].bench_slot)
	check(main.selected == bench[0], "il clic in panchina seleziona l'unità")
	main._on_cell_pressed(Vector2i(3, 0))
	check(player.unit_at_cell(Vector2i(3, 0)) != null, "l'unità selezionata viene schierata")
	check(main.selected == null, "dopo il piazzamento la selezione si azzera")

	# Rimessa in panchina. Se lo slot è già occupato le due unità si scambiano,
	# quindi la cella può restare piena: ciò che conta è dove finisce QUESTA
	# unità, non che la cella si svuoti.
	main._on_cell_pressed(Vector2i(3, 0))
	check(main.selected != null, "il clic su una cella occupata seleziona l'unità")
	var moved: UnitInstance = main.selected
	main._on_bench_slot_pressed(0)
	check(not moved.is_on_board() and moved.bench_slot == 0,
		"l'unità torna in panchina nello slot scelto",
		"in campo=%s slot=%d" % [moved.is_on_board(), moved.bench_slot])

	# Vendita.
	var before_gold := player.gold
	var count_before := player.units.size()
	main._on_bench_slot_pressed(player.bench_units()[0].bench_slot)
	main._on_sell_pressed()
	check(player.units.size() == count_before - 1, "la vendita rimuove l'unità")
	check(player.gold > before_gold, "la vendita restituisce oro")

	# Aggiornamento negozio ed esperienza.
	player.gold = 50
	main._on_reroll_pressed()
	main._on_buy_xp_pressed()
	check(player.gold < 50, "aggiornare e comprare esperienza costano oro")

	# Il tempo di preparazione vale anche in singolo: allo scadere il round parte
	# da solo, senza che nessuno prema COMBATTI. Il conto alla rovescia gira in
	# _process, che in questo test sincrono non scatta mai, quindi lo si chiama
	# a mano con un passo lungo quanto tutta la fase.
	check(main._prep_left > 0.0, "in locale la preparazione ha un conto alla rovescia",
		"%.1f s" % main._prep_left)
	check(is_equal_approx(main._prep_phase_bar.total,
			float(GameData.balance()["rounds"]["preparation_seconds"])),
		"la barra dura quanto la fase", "%.1f s" % main._prep_phase_bar.total)
	main._process(main._prep_phase_bar.total * 0.5)
	# Tolleranza: anche il motore chiama _process, e i suoi fotogrammi si
	# sommano a quello simulato qui.
	check(absf(main._prep_phase_bar.ratio() - 0.5) < 0.05,
		"a metà fase la barra è a metà", "%.3f" % main._prep_phase_bar.ratio())

	var round_before: int = main.match_state.round_index
	main._process(main._prep_left + 0.1)
	check(main._prep_left < 0.0, "scaduto il tempo il conto alla rovescia si disarma",
		"%.1f" % main._prep_left)
	check(main.match_state.round_index != round_before or main._combat_overlay.visible,
		"allo scadere il round parte da solo")
	if main._combat_overlay.visible:
		main._combat_view.skip_to_end()
		main._close_combat_overlay()
	check(main._prep_left > 0.0, "il round successivo riarma il conto alla rovescia",
		"%.1f s" % main._prep_left)

	# Gioca la partita fino alla fine premendo "Combatti". Quando compare la
	# battaglia la si salta, come farebbe chi ha fretta.
	var rounds := 0
	var battles_watched := 0
	while main.match_state.phase != MatchState.Phase.FINISHED and rounds < 200:
		main._on_fight_pressed()
		if main._combat_overlay.visible:
			battles_watched += 1
			check_once("la battaglia carica le unità nella vista",
				not main._combat_view._units.is_empty())
			check_once("la battaglia ha i nodi ritratto eroe agli angoli",
				main._combat_view._self_hero_portrait != null
				and main._combat_view._opponent_hero_portrait != null)
			main._combat_view.skip_to_end()
			check_once("a fine battaglia compare l'esito", main._combat_outcome.text != "")
			# Non c'è più un pulsante per uscire: la battaglia si chiude da sola.
			# Il conto alla rovescia gira in _process, che in questo ciclo
			# sincrono non scatta mai, quindi il test chiama direttamente ciò che
			# il timer chiamerebbe.
			check_once("a fine battaglia l'uscita automatica è armata",
				main._auto_close_left >= 0.0 or not main._combat_overlay.visible)
			main._close_combat_overlay()
			check_once("chiusa la battaglia si torna alla preparazione",
				not main._combat_overlay.visible)
		rounds += 1
	check(battles_watched > 0, "il giocatore assiste alle proprie battaglie", str(battles_watched))
	check(main.match_state.phase == MatchState.Phase.FINISHED,
		"la partita si conclude premendo Combatti", "round: %d" % rounds)
	# Confronto senza distinzione di maiuscole: che l'etichetta sia "Nuova
	# partita" o "NUOVA PARTITA" è una scelta tipografica, non un comportamento.
	check(main._fight_button.text.to_lower() == "nuova partita",
		"a fine partita il pulsante propone una nuova partita",
		main._fight_button.text)

	# La partita finita deve essere finita anche nella cronologia locale: e'
	# l'unico posto dove una partita contro il computer viene conservata.
	var history := MatchLog.local_matches()
	check(history.size() == history_before + 1,
		"la partita conclusa entra nella cronologia locale",
		"%d -> %d" % [history_before, history.size()])
	if not history.is_empty():
		check(int(history[0].get("placement", 0)) == main.player().placement,
			"la cronologia registra il piazzamento vero")
		check(not (history[0].get("units", []) as Array).is_empty()
				or main.player().board_units().is_empty(),
			"la cronologia registra la formazione finale")

	# Riavvio.
	main._on_fight_pressed()
	check(main.match_state.phase == MatchState.Phase.PREPARATION, "si può iniziare una nuova partita")

	_check_unit_slots(main)

	# Il test ha marcato "shop" come visto sul profilo vero: senza rimetterlo a
	# posto, chi sviluppa non vedrebbe più quel suggerimento in una partita reale.
	profile.seen_tips = saved_tips
	profile.save_profile()

	var restore := FileAccess.open(MatchLog.HISTORY_PATH, FileAccess.WRITE)
	if restore != null:
		restore.store_string(JSON.stringify(saved_history))
		restore.close()
	var telemetry_restore := FileAccess.open(MatchLog.TELEMETRY_PATH, FileAccess.WRITE)
	if telemetry_restore != null:
		telemetry_restore.store_string(saved_telemetry)
		telemetry_restore.close()

	print("\n%d superati, %d falliti" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


var _seen: Dictionary = {}


## Come check(), ma dentro un ciclo: registra l'esito una volta sola, e se una
## sola iterazione fallisce vince il fallimento.
func check_once(label: String, condition: bool) -> void:
	if _seen.has(label):
		if not condition and bool(_seen[label]):
			_seen[label] = false
			_passed -= 1
			_failed += 1
			printerr("  FAIL %s (in un round successivo)" % label)
		return
	_seen[label] = condition
	check(condition, label)


func check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % label)
	else:
		_failed += 1
		printerr("  FAIL %s%s" % [label, ("  -> " + detail) if detail != "" else ""])


## Le caselle mostrano il modello 3D dell'unità. Qui non c'è rendering (test
## headless), quindi si verifica soprattutto il ripiego: senza figura deve
## restare il nome, altrimenti una casella piena sarebbe indistinguibile da
## una vuota.
func _check_unit_slots(main: Control) -> void:
	var portraits := main.get_node("/root/Portraits")
	check(not portraits.is_available(),
		"senza schermo i ritratti sono disattivati")
	check(portraits.texture_for("legionarius") == null,
		"senza schermo non viene prodotta alcuna texture")

	var player: Player = main.player()
	player.gold = 100
	main._refresh()

	var slot: UnitSlot = main._shop_buttons[0]
	var offered: UnitDef = player.shop[0]
	if offered != null:
		check(slot.unit_id == offered.id, "la casella del negozio conosce la propria unità")
		check(slot._fallback.visible and slot._fallback.text != "",
			"senza ritratto la casella mostra il nome")
		check(slot._hover_text.contains(offered.display_name),
			"il nome completo resta nel suggerimento")
		check(slot._badge.text == "%d oro" % offered.cost,
			"il negozio mostra il costo", slot._badge.text)

	# Una casella con un'unità schierata mostra le stelle al posto del costo.
	var unit := player.grant_unit("legionarius", 2)
	player.move_to_board(unit, Vector2i(0, 0))
	main._refresh()
	var cell_slot: UnitSlot = main._cell_buttons[Vector2i(0, 0)]
	check(cell_slot.unit_id == "legionarius", "la casella in campo conosce la propria unità")
	check(cell_slot._badge.text == "★★", "in campo il distintivo mostra le stelle", cell_slot._badge.text)

	player.sell(unit)
	main._refresh()
	check(cell_slot.unit_id == "" and cell_slot._badge.text == "",
		"togliendo l'unità la casella torna vuota")
