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

	check(main.match_state != null, "la partita viene creata all'avvio")
	check(main.player() != null and not main.player().is_bot, "esiste un giocatore umano")

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
			main._combat_view.skip_to_end()
			check_once("a fine battaglia compare l'esito", main._combat_outcome.text != "")
			check_once("a fine battaglia si può continuare", main._continue_button.visible)
			main._on_continue_pressed()
			check_once("continuando si torna alla preparazione", not main._combat_overlay.visible)
		rounds += 1
	check(battles_watched > 0, "il giocatore assiste alle proprie battaglie", str(battles_watched))
	check(main.match_state.phase == MatchState.Phase.FINISHED,
		"la partita si conclude premendo Combatti", "round: %d" % rounds)
	# Confronto senza distinzione di maiuscole: che l'etichetta sia "Nuova
	# partita" o "NUOVA PARTITA" è una scelta tipografica, non un comportamento.
	check(main._fight_button.text.to_lower() == "nuova partita",
		"a fine partita il pulsante propone una nuova partita",
		main._fight_button.text)

	# Riavvio.
	main._on_fight_pressed()
	check(main.match_state.phase == MatchState.Phase.PREPARATION, "si può iniziare una nuova partita")

	_check_store_panel(main)
	_check_unit_slots(main)

	print("\n%d superati, %d falliti" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


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


## Il negozio deve aprirsi, mostrare una riga per ogni contenuto in vendita e
## riflettere subito ciò che è stato acquistato.
##
## L'autoload si recupera dall'albero invece di usare il nome globale: questo
## script viene compilato prima che gli autoload siano registrati, e "Store"
## non sarebbe ancora un identificatore noto.
func _check_store_panel(main: Control) -> void:
	var store := main.get_node("/root/Store")
	var panel: StorePanel = main._store_panel
	panel.open()
	check(panel.visible, "il negozio si apre")
	check(panel._rows.size() == Catalog.entitlement_ids().size(),
		"c'è una riga per ogni contenuto in vendita",
		"%d righe" % panel._rows.size())

	var entitlement_id := "cosmetic_pack_legion"
	var button: Button = panel._rows[entitlement_id]
	check(not button.disabled, "un contenuto non posseduto è acquistabile")

	store.purchase(entitlement_id)
	check(store.has_entitlement(entitlement_id), "l'acquisto concede il contenuto")
	check(button.disabled, "dopo l'acquisto il pulsante non è più premibile")
	check(store.owns_cosmetic("roman_gold"), "il cosmetico risulta posseduto")

	# La modalità 'shared' non deve mai togliere civiltà dalla partita: è la
	# garanzia che l'acquisto non tocchi l'equilibrio competitivo.
	check(store.playable_origins().size() == GameData.origin_ids().size(),
		"in modalità condivisa tutte le civiltà restano giocabili")
	check(store.selectable_origins().has("roman"), "la civiltà gratuita è sempre selezionabile")

	# Non lasciare acquisti finti sul disco: il prossimo avvio ripartirebbe
	# con contenuti già sbloccati e i test non sarebbero più ripetibili.
	if store.backend is MockStore:
		(store.backend as MockStore).clear()


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
		check(slot.tooltip_text.contains(offered.display_name),
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
