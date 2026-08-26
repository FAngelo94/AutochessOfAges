extends Control

## Schermata di gioco. Costruisce l'interfaccia da codice: a questo stadio i
## controlli cambiano di continuo e un .tscn scritto a mano sarebbe solo un
## file difficile da leggere in più.
##
## Questo script LEGGE lo stato della partita e invia comandi; non calcola
## nulla. Ogni regola sta in core/. Se qui comparisse un numero di
## bilanciamento, sarebbe nel posto sbagliato.

## Le caselle ospitano il modello 3D dell'unità: sono più alte che larghe per
## lasciare spazio alla figura sopra il distintivo di costo o stelle.
## Proporzioni di un esagono con la punta in alto: la larghezza sta all'altezza
## come √3 sta a 2. Rispettarle è ciò che permette alle righe di incastrarsi.
const CELL_SIZE := Vector2(76, 88)
const SHOP_SLOT_SIZE := Vector2(92, 96)
const BENCH_SLOT_SIZE := SHOP_SLOT_SIZE

var match_state: MatchState
var brains: Array[BotBrain] = []
var selected: UnitInstance = null

var _round_label: Label
var _hp_label: Label
var _gold_label: Label
var _level_label: Label
var _stats_label: Label
var _log_label: RichTextLabel
var _shop_row: HBoxContainer
var _board_rows: VBoxContainer
var _bench_row: HBoxContainer
var _ranking_list: VBoxContainer
var _synergy_row: HFlowContainer
var _fight_button: Button
var _sell_button: Button

## I controlli di negozio, griglia e panchina hanno numero fisso: vengono
## creati una volta sola e poi solo aggiornati. Ricostruirli a ogni refresh
## significherebbe distruggere il pulsante dentro il cui gestore ci troviamo,
## e accumulare nodi in attesa di queue_free() a ogni interazione.
var _shop_buttons: Array[UnitSlot] = []
var _cell_buttons: Dictionary = {}
var _bench_buttons: Array[UnitSlot] = []

var _store: Node
var _profile: Node
var _store_panel: StorePanel
var _combat_overlay: Control
var _combat_controls: Control
var _info_sheet: Panel
var _synergy_detail: Panel
var _synergy_detail_title: Label
var _synergy_detail_description: Label
var _synergy_detail_tiers: VBoxContainer
var _combat_view: CombatView
var _combat_title: Label
var _combat_outcome: Label
var _continue_button: Button
var _exit_confirm: ConfirmationDialog
## Risultati del round in attesa: vengono raccontati solo a fine replay, per
## non svelare l'esito mentre la battaglia è ancora in corso.
var _pending_results: Array = []


func _ready() -> void:
	GameData.ensure_loaded()
	_store = get_node("/root/Store")
	_profile = get_node("/root/Profile")
	_build_ui()
	_build_slot_buttons()
	_start_new_match()


func player() -> Player:
	return match_state.human_player()


## Seed della partita. Normalmente casuale, ma si può fissare da riga di
## comando:
##
##   godot --path . -- --seed=4242
##
## Serve a riprodurre una partita identica — per inseguire un bug segnalato,
## o per avere test ripetibili invece che dipendenti dall'orologio.
func _requested_seed() -> int:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--seed="):
			return int(argument.trim_prefix("--seed="))
	return 0


# --------------------------------------------------------------------------
# Costruzione dell'interfaccia
# --------------------------------------------------------------------------

func _build_ui() -> void:
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	# In alto la tacca del telefono, in basso la barra dei gesti.
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	root.add_child(_build_hud())

	# Il centro scorre, le due barre no: su un telefono 16:9 griglia, panchina e
	# negozio insieme non ci stanno in altezza, ma vita e oro in cima e Combatti
	# in fondo devono restare dove sono senza doverli cercare.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)

	body.add_child(_section_title("SCHIERAMENTO — la prima fila è a contatto col nemico"))

	# Il campo e la classifica avversari stanno affiancati: si guardano insieme
	# mentre si decide come schierare, invece di dover aprire un altro foglio.
	var battlefield_row := HBoxContainer.new()
	battlefield_row.add_theme_constant_override("separation", 14)
	battlefield_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	body.add_child(battlefield_row)

	# Una riga per HBox invece di una griglia unica: il campo è esagonale, e le
	# righe dispari vanno sfalsate di mezza cella. Una GridContainer allinea le
	# colonne per costruzione, e mostrerebbe adiacenze che in battaglia non
	# esistono — chi schiera deve vedere gli stessi vicini che vedrà il
	# risolutore.
	_board_rows = VBoxContainer.new()
	_board_rows.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# Separazione negativa: due righe di esagoni si incastrano risalendo di un
	# quarto d'altezza l'una sull'altra. Con una separazione positiva resterebbero
	# due file di esagoni staccate, che non è una griglia esagonale.
	_board_rows.add_theme_constant_override("separation", int(-CELL_SIZE.y * 0.25))
	battlefield_row.add_child(_board_rows)

	battlefield_row.add_child(_build_ranking_panel())

	body.add_child(_spacer(6))
	body.add_child(_section_title("SINERGIE"))
	body.add_child(_build_synergy_card())

	body.add_child(_spacer(6))
	body.add_child(_section_title("PANCHINA"))

	_bench_row = HBoxContainer.new()
	_bench_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_bench_row.add_theme_constant_override("separation", 4)
	body.add_child(_bench_row)

	body.add_child(_spacer(6))
	body.add_child(_section_title("NEGOZIO"))

	_shop_row = HBoxContainer.new()
	_shop_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_shop_row.add_theme_constant_override("separation", 6)
	body.add_child(_shop_row)

	var shop_actions := HBoxContainer.new()
	shop_actions.add_theme_constant_override("separation", 10)
	body.add_child(shop_actions)

	# Sui pulsanti del negozio il prezzo va sotto il verbo e non dentro la stessa
	# riga: in portrait "Compra esperienza (4 oro)" su una riga sola verrebbe
	# troncato, ed è proprio il numero a sparire per primo.
	var reroll := _shop_action(
		"Aggiorna", "%d oro" % int(GameData.balance()["economy"]["reroll_cost"]))
	reroll.pressed.connect(_on_reroll_pressed)
	shop_actions.add_child(reroll)

	var buy_xp := _shop_action(
		"Esperienza", "%d oro" % int(GameData.balance()["economy"]["buy_xp_cost"]))
	buy_xp.pressed.connect(_on_buy_xp_pressed)
	shop_actions.add_child(buy_xp)

	root.add_child(_build_action_bar())

	# Sovrapposizioni, dalla meno alla più invadente: l'ordine di aggiunta è
	# l'ordine di disegno, e la battaglia deve poter coprire tutto il resto.
	_build_info_sheet()

	_store_panel = StorePanel.new()
	add_child(_store_panel)

	_build_combat_overlay()


## Barra di stato: round, vita, oro, livello. Sono i quattro numeri su cui si
## decide ogni turno, quindi stanno in cima e non scorrono via.
func _build_hud() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)

	_round_label = Label.new()
	_round_label.add_theme_font_size_override("font_size", 26)
	_round_label.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(_round_label)

	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 8)
	column.add_child(chips)

	_hp_label = _chip(chips, "❤", Color(0.92, 0.45, 0.45))
	_gold_label = _chip(chips, "⛁", Style.GOLD)
	_level_label = _chip(chips, "⬆", Style.BLUE)

	_stats_label = Label.new()
	_stats_label.add_theme_font_size_override("font_size", 18)
	_stats_label.add_theme_color_override("font_color", Style.TEXT_DIM)
	column.add_child(_stats_label)

	return column


func _chip(row: HBoxContainer, icon: String, tint: Color) -> Label:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Style.plate(Style.PLATE_DARK, Style.PLATE, 12, 3))
	row.add_child(panel)

	var box := HBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var glyph := Label.new()
	glyph.text = icon
	glyph.add_theme_font_size_override("font_size", 22)
	glyph.add_theme_color_override("font_color", tint)
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	box.add_child(glyph)

	var value := Label.new()
	value.add_theme_font_size_override("font_size", 22)
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	box.add_child(value)
	return value


## Pulsante del negozio con il prezzo accanto all'azione. Su una riga sola e
## non su due: il testo dei Button in Godot 4 non va a capo sugli "\n" se
## l'autowrap è spento, e il risultato sarebbe le due parti attaccate.
func _shop_action(title: String, price: String) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(0, 56)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.text = "%s · %s" % [title, price]
	button.add_theme_font_size_override("font_size", 17)
	Style.apply_plate(button, Style.PLATE, Style.PLATE_DARK, 14, 4)
	return button


## Le due file di comandi in fondo: le azioni di contorno sopra, Combatti da
## solo sotto. Il pollice riposa lì, e quello è il pulsante che si preme più
## spesso — accanto agli altri finirebbe premuto per sbaglio.
func _build_action_bar() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)

	var minor := HBoxContainer.new()
	minor.add_theme_constant_override("separation", 8)
	column.add_child(minor)

	# Vendi porta una parola e un numero, gli altri tre una sola icona: a fette
	# uguali il primo verrebbe troncato e gli altri sprecherebbero spazio.
	_sell_button = _bar_button(minor, "Vendi", Style.PLATE)
	_sell_button.size_flags_stretch_ratio = 2.0
	_sell_button.disabled = true
	_sell_button.pressed.connect(_on_sell_pressed)

	_bar_button(minor, "🛒", Style.PLATE).pressed.connect(func() -> void: _store_panel.open())
	_bar_button(minor, "ⓘ", Style.PLATE).pressed.connect(func() -> void: _info_sheet.visible = true)
	_bar_button(minor, "☰", Style.PLATE).pressed.connect(_on_menu_button_pressed)

	_fight_button = Button.new()
	_fight_button.text = "COMBATTI"
	_fight_button.custom_minimum_size = Vector2(0, Style.TOUCH_PRIMARY)
	_fight_button.add_theme_font_size_override("font_size", 38)
	_fight_button.add_theme_color_override("font_color", Style.INK)
	_fight_button.add_theme_color_override("font_hover_color", Style.INK)
	_fight_button.add_theme_color_override("font_pressed_color", Style.INK)
	Style.apply_plate(_fight_button, Style.GOLD, Style.GOLD_DEEP, 20, 8)
	_fight_button.pressed.connect(_on_fight_pressed)
	column.add_child(_fight_button)

	return column


func _bar_button(row: HBoxContainer, text: String, fill: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 24)
	Style.apply_plate(button, fill, Style.PLATE_DARK, 16, 5)
	row.add_child(button)
	return button


## Cronaca in un foglio richiamabile invece che in colonna a lato: in portrait
## una seconda colonna non esiste, ed è il registro della battaglia — non le
## sinergie, ora sulla schermata principale — la cosa che si consulta ogni
## tanto e non a ogni tocco come griglia e negozio.
func _build_info_sheet() -> void:
	_info_sheet = Panel.new()
	_info_sheet.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_info_sheet.add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	_info_sheet.visible = false
	add_child(_info_sheet)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	_info_sheet.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	column.add_child(_section_title("CRONACA"))

	_log_label = RichTextLabel.new()
	_log_label.bbcode_enabled = true
	_log_label.add_theme_font_size_override("normal_font_size", 18)
	_log_label.add_theme_font_size_override("bold_font_size", 18)
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_log_label)

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 24)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 16, 5)
	close.pressed.connect(func() -> void: _info_sheet.visible = false)
	column.add_child(close)


## Schermata di battaglia: copre il gioco mentre la si guarda, e si può
## accelerare o saltare. Sta sopra a tutto, quindi va aggiunta per ultima.
func _build_combat_overlay() -> void:
	_combat_overlay = Panel.new()
	_combat_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_combat_overlay.add_theme_stylebox_override("panel", Style.box(Style.INK, Style.INK, 0, 0))
	_combat_overlay.visible = false
	add_child(_combat_overlay)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	_combat_overlay.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	_combat_title = Label.new()
	_combat_title.add_theme_font_size_override("font_size", 24)
	_combat_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_combat_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_combat_title)

	# La battaglia si prende tutto lo spazio che avanza: la camera 3D si adatta
	# al riquadro, quindi darle l'altezza residua è l'unico modo perché su un
	# telefono lungo non resti una cartolina in mezzo allo schermo.
	_combat_view = CombatView.new()
	_combat_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_combat_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_combat_view.playback_finished.connect(_on_playback_finished)
	box.add_child(_combat_view)

	_combat_outcome = Label.new()
	_combat_outcome.add_theme_font_size_override("font_size", 26)
	_combat_outcome.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_combat_outcome.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_combat_outcome)

	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)
	box.add_child(controls)

	for speed in [1.0, 2.0, 4.0]:
		var button := Button.new()
		button.text = "×%d" % int(speed)
		button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 24)
		Style.apply_plate(button, Style.PLATE, Style.PLATE_DARK, 16, 5)
		button.pressed.connect(func() -> void: _combat_view.speed = speed)
		controls.add_child(button)

	var skip := Button.new()
	skip.text = "Salta"
	skip.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	skip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skip.add_theme_font_size_override("font_size", 24)
	Style.apply_plate(skip, Style.PLATE, Style.PLATE_DARK, 16, 5)
	skip.pressed.connect(func() -> void: _combat_view.skip_to_end())
	controls.add_child(skip)

	# Continua sostituisce i comandi di riproduzione a battaglia finita: è
	# l'unica cosa che ha ancora senso premere, e in portrait la fila di quattro
	# pulsanti più un quinto non ci starebbe comunque.
	_continue_button = Button.new()
	_continue_button.text = "CONTINUA"
	_continue_button.custom_minimum_size = Vector2(0, Style.TOUCH_PRIMARY)
	_continue_button.add_theme_font_size_override("font_size", 34)
	_continue_button.add_theme_color_override("font_color", Style.INK)
	_continue_button.add_theme_color_override("font_hover_color", Style.INK)
	_continue_button.add_theme_color_override("font_pressed_color", Style.INK)
	Style.apply_plate(_continue_button, Style.GOLD, Style.GOLD_DEEP, 20, 8)
	_continue_button.visible = false
	_continue_button.pressed.connect(_on_continue_pressed)
	box.add_child(_continue_button)

	_combat_controls = controls


## Riquadro accanto allo schieramento con gli avversari ordinati per vita
## rimasta: dice a colpo d'occhio chi è messo peggio, senza dover aprire il
## foglio delle sinergie per controllare i piazzamenti.
func _build_ranking_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(150, 0)
	panel.add_theme_stylebox_override("panel", Style.plate(Style.PLATE, Style.PLATE_DARK, 12, 4))

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	panel.add_child(column)

	var title := Label.new()
	title.text = "AVVERSARI"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Style.GOLD.darkened(0.2))
	column.add_child(title)

	_ranking_list = VBoxContainer.new()
	_ranking_list.add_theme_constant_override("separation", 2)
	column.add_child(_ranking_list)

	return panel


## Ricostruisce la classifica: gli avversari sono pochi (fino a 7) e cambiano
## posizione a ogni round, quindi rifare le righe da zero costa meno che
## tenerle in sincrono manualmente.
func _refresh_ranking() -> void:
	if _ranking_list == null:
		return
	for child in _ranking_list.get_children():
		child.queue_free()

	var opponents: Array[Player] = []
	for pl in match_state.players:
		if pl != player():
			opponents.append(pl)
	opponents.sort_custom(func(a: Player, b: Player) -> bool: return a.hp > b.hp)

	for pl in opponents:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_ranking_list.add_child(row)

		var name_label := Label.new()
		name_label.text = pl.display_name
		name_label.add_theme_font_size_override("font_size", 15)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		row.add_child(name_label)

		var hp_label := Label.new()
		hp_label.add_theme_font_size_override("font_size", 15)
		row.add_child(hp_label)

		if pl.eliminated or pl.hp <= 0:
			hp_label.text = "☠"
			name_label.add_theme_color_override("font_color", Style.TEXT_DIM)
			hp_label.add_theme_color_override("font_color", Style.TEXT_DIM)
		else:
			hp_label.text = str(pl.hp)
			hp_label.add_theme_color_override("font_color", Color(0.92, 0.45, 0.45))


## Riquadro sinergie sulla schermata principale: una fila di chip che va a capo
## da sola, una per tratto presente in squadra. Sostituisce la vecchia lista
## testuale nel foglio informazioni — qui si controlla senza dover aprire
## nulla, ed è cliccabile per il dettaglio dei bonus.
func _build_synergy_card() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Style.plate(Style.PLATE, Style.PLATE_DARK, 12, 4))

	_synergy_row = HFlowContainer.new()
	_synergy_row.add_theme_constant_override("h_separation", 6)
	_synergy_row.add_theme_constant_override("v_separation", 6)
	panel.add_child(_synergy_row)

	_build_synergy_detail()

	return panel


## Aggiorna le chip delle sinergie. Vengono ricreate a ogni refresh come la
## classifica avversari: il numero di tratti presenti cambia a ogni mossa, e
## tenerle in sincrono manualmente costerebbe più che rifarle.
func _refresh_synergies() -> void:
	if _synergy_row == null:
		return
	for child in _synergy_row.get_children():
		child.queue_free()

	var rows := TraitResolver.summary(player().board_units())
	if rows.is_empty():
		var label := Label.new()
		label.text = "Nessuna sinergia attiva."
		label.add_theme_font_size_override("font_size", 16)
		label.add_theme_color_override("font_color", Style.TEXT_DIM)
		_synergy_row.add_child(label)
		return

	for row in rows:
		_synergy_row.add_child(_synergy_chip(row))


func _synergy_chip(row: Dictionary) -> Button:
	var button := Button.new()
	var progress := "%d" % int(row["count"])
	if int(row["next_threshold"]) > 0:
		progress = "%d/%d" % [int(row["count"]), int(row["next_threshold"])]
	button.text = "%s %s %s" % ["●" if bool(row["active"]) else "○", row["name"], progress]
	button.add_theme_font_size_override("font_size", 16)
	button.custom_minimum_size = Vector2(0, 44)

	var tint: Color = Style.origin_color(String(row["id"])) if bool(row["is_origin"]) else Style.BLUE
	if bool(row["active"]):
		Style.apply_plate(button, tint.darkened(0.55), tint, 12, 4)
		button.add_theme_color_override("font_color", tint.lightened(0.35))
	else:
		Style.apply_plate(button, Style.PLATE_DARK, Style.PLATE, 12, 3)
		button.add_theme_color_override("font_color", Style.TEXT_DIM)

	button.pressed.connect(_open_synergy_detail.bind(String(row["id"])))
	return button


## Pannello di dettaglio di una singola sinergia: tutte le soglie con il
## relativo bonus, quella raggiunta evidenziata in oro. Costruito una sola
## volta e ripopolato a ogni apertura, come il foglio informazioni.
func _build_synergy_detail() -> void:
	_synergy_detail = Panel.new()
	_synergy_detail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_synergy_detail.add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	_synergy_detail.visible = false
	add_child(_synergy_detail)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	_synergy_detail.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	_synergy_detail_title = Label.new()
	_synergy_detail_title.add_theme_font_size_override("font_size", 26)
	_synergy_detail_title.add_theme_color_override("font_color", Style.GOLD)
	_synergy_detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_synergy_detail_title)

	_synergy_detail_description = Label.new()
	_synergy_detail_description.add_theme_font_size_override("font_size", 18)
	_synergy_detail_description.add_theme_color_override("font_color", Style.TEXT_DIM)
	_synergy_detail_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_synergy_detail_description)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	_synergy_detail_tiers = VBoxContainer.new()
	_synergy_detail_tiers.add_theme_constant_override("separation", 10)
	_synergy_detail_tiers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_synergy_detail_tiers)

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 24)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 16, 5)
	close.pressed.connect(func() -> void: _synergy_detail.visible = false)
	column.add_child(close)


## Popola e apre il dettaglio di una sinergia: tutte le soglie definite in
## traits.json, non solo quella attiva, così si vede anche cosa serve ancora.
func _open_synergy_detail(trait_id: String) -> void:
	var def := GameData.trait_def(trait_id)
	var count := int(TraitResolver.count_traits(player().board_units()).get(trait_id, 0))

	_synergy_detail_title.text = String(def.get("name", trait_id))
	_synergy_detail_description.text = String(def.get("description", ""))

	for child in _synergy_detail_tiers.get_children():
		child.queue_free()

	for tier in def.get("tiers", []):
		var required := int(tier["count"])
		var reached := count >= required

		var row := PanelContainer.new()
		if reached:
			row.add_theme_stylebox_override("panel", Style.plate(Style.GOLD_DEEP.darkened(0.35), Style.GOLD, 12, 4))
		else:
			row.add_theme_stylebox_override("panel", Style.plate(Style.PLATE_DARK, Style.PLATE, 12, 3))
		_synergy_detail_tiers.add_child(row)

		var inner := VBoxContainer.new()
		inner.add_theme_constant_override("separation", 4)
		row.add_child(inner)

		var heading := Label.new()
		heading.text = "%d unità %s" % [required, "— raggiunta" if reached else ""]
		heading.add_theme_font_size_override("font_size", 18)
		heading.add_theme_color_override("font_color", Style.GOLD if reached else Style.TEXT_DIM)
		inner.add_child(heading)

		var effect_text := Label.new()
		effect_text.text = String(tier.get("text", ""))
		effect_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		effect_text.add_theme_font_size_override("font_size", 17)
		inner.add_child(effect_text)

	_synergy_detail.visible = true


func _section_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Style.GOLD.darkened(0.2))
	return label


func _spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


# --------------------------------------------------------------------------
# Partita
# --------------------------------------------------------------------------

func _start_new_match() -> void:
	_combat_view.pause()
	_combat_overlay.visible = false
	_pending_results = []
	_fight_button.text = "COMBATTI"
	selected = null

	match_state = MatchState.new(_requested_seed(), 1)
	brains.clear()
	var brain_rng := SimRNG.new(match_state.seed_value ^ 0x5EED)
	for p in match_state.players:
		if p.is_bot:
			brains.append(BotBrain.new(p, brain_rng.fork(p.index)))

	_log("[b]Nuova partita[/b] (seed %d)" % match_state.seed_value)
	_log("Civiltà disponibili: %s" % ", ".join(_store.playable_origins()))
	match_state.start_round()
	_refresh()


func _on_fight_pressed() -> void:
	if _combat_overlay.visible:
		return
	if match_state.phase == MatchState.Phase.FINISHED:
		_start_new_match()
		return

	for brain in brains:
		brain.play_preparation(match_state.stage)

	var results := match_state.resolve_round()
	var own := _own_result(results)

	# Niente replay se non c'è nulla da guardare: giocatore già eliminato,
	# round senza avversario, o due schieramenti vuoti.
	if own.is_empty() or own["combat"].is_empty() or own["combat"]["initial"].is_empty():
		_conclude_round(results)
		return

	_pending_results = results
	_show_combat(own)


## Il risultato del round dal punto di vista del giocatore umano.
func _own_result(results: Array) -> Dictionary:
	for result in results:
		if result["player"] == player():
			return result
	return {}


func _show_combat(own: Dictionary) -> void:
	var opponent: Player = own["opponent"]
	_combat_title.text = "Round %s — contro %s" % [
		_previous_round_label(), opponent.display_name if opponent != null else "nessuno",
	]
	_combat_outcome.text = ""
	_continue_button.visible = false
	_combat_controls.visible = true

	_combat_view.speed = float(_profile.combat_speed)
	_combat_view.load_combat(own["combat"], int(own.get("team", 0)))
	_combat_overlay.visible = true
	_combat_view.play()


## resolve_round() ha già fatto avanzare il contatore, quindi la battaglia
## appena combattuta è quella del round precedente.
func _previous_round_label() -> String:
	var rounds_per_stage := int(GameData.balance()["rounds"]["rounds_per_stage"])
	var index := match_state.round_index - 1
	var stage := match_state.stage
	if index < 1:
		index = rounds_per_stage
		stage -= 1
	return "%d-%d" % [stage, index]


func _on_playback_finished() -> void:
	var own := _own_result(_pending_results)
	if own.is_empty():
		_on_continue_pressed()
		return

	if bool(own["won"]):
		_combat_outcome.text = "Vittoria"
		_combat_outcome.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5))
	else:
		_combat_outcome.text = "Sconfitta — %d danni alla tua vita" % int(own["damage"])
		_combat_outcome.add_theme_color_override("font_color", Color(0.9, 0.45, 0.45))
	_continue_button.visible = true
	_combat_controls.visible = false


func _on_continue_pressed() -> void:
	_combat_view.pause()
	_combat_overlay.visible = false
	var results := _pending_results
	_pending_results = []
	_conclude_round(results)


## Chiude il round: racconto dell'esito, preparazione del successivo.
func _conclude_round(results: Array) -> void:
	_report(results)

	if match_state.phase == MatchState.Phase.FINISHED:
		var standings := match_state.standings()
		_log("\n[b]Partita conclusa.[/b] Vince %s." % standings[0].display_name)
		_log("Il tuo piazzamento: %d° su %d." % [player().placement, match_state.players.size()])
		_fight_button.text = "NUOVA PARTITA"
		_profile.record_match(player().placement)
	else:
		match_state.start_round()
	_refresh()


## Chiede conferma prima di lasciare il combattimento: uscire abbandona la
## partita in corso (il cambio di scena la distrugge), quindi un tocco per
## sbaglio sul menu non deve poter buttare via un round già in corso.
func _on_menu_button_pressed() -> void:
	if _exit_confirm == null:
		_exit_confirm = ConfirmationDialog.new()
		_exit_confirm.dialog_text = "Uscire dal combattimento? La partita in corso andrà persa."
		_exit_confirm.ok_button_text = "Esci"
		_exit_confirm.cancel_button_text = "Annulla"
		_exit_confirm.confirmed.connect(_on_menu_pressed)
		add_child(_exit_confirm)
	_exit_confirm.popup_centered()


## Torna alla schermata iniziale. La partita in corso viene abbandonata: il
## cambio di scena la distrugge, e questo è il motivo per cui il menu è una
## scena separata invece di un pannello sovrapposto.
func _on_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://ui/menu.tscn")


## Mostra l'esito del round dal punto di vista del giocatore umano, più un
## riepilogo di chi è ancora in gioco.
func _report(results: Array) -> void:
	var human := player()
	_log("\n[b]Round %s[/b]" % match_state.round_label())

	for result in results:
		if result["player"] != human:
			continue
		var opponent: Player = result["opponent"]
		var opponent_name: String = opponent.display_name if opponent != null else "nessuno"
		if bool(result["won"]):
			_log("  [color=#7fd67f]Vittoria[/color] contro %s" % opponent_name)
		else:
			_log("  [color=#e07070]Sconfitta[/color] contro %s (−%d vita)" % [opponent_name, int(result["damage"])])
		var combat: Dictionary = result["combat"]
		if not combat.is_empty():
			_log("  durata %.1fs" % float(combat["duration"]))

	if human.eliminated:
		_log("  [color=#e07070]Sei stato eliminato: %d° posto.[/color]" % human.placement)

	_log("  in gioco: %d" % match_state.alive_players().size())


func _on_reroll_pressed() -> void:
	if not player().reroll():
		_log("[color=#e0a070]Oro insufficiente per aggiornare il negozio.[/color]")
	_refresh()


func _on_buy_xp_pressed() -> void:
	if not player().buy_xp():
		_log("[color=#e0a070]Non puoi comprare esperienza adesso.[/color]")
	_refresh()


func _on_sell_pressed() -> void:
	if selected == null:
		return
	var value := selected.sell_value()
	var name := selected.def.display_name
	player().sell(selected)
	selected = null
	_log("Venduto %s per %d oro." % [name, value])
	_refresh()


func _on_shop_slot_pressed(slot: int) -> void:
	var p := player()
	if p.shop[slot] == null:
		return
	if not p.can_buy(slot):
		var def: UnitDef = p.shop[slot]
		if p.gold < def.cost:
			_log("[color=#e0a070]Servono %d oro per %s.[/color]" % [def.cost, def.display_name])
		else:
			_log("[color=#e0a070]Panchina piena.[/color]")
		return
	var bought := p.buy(slot)
	_log("Comprato %s." % bought)
	_refresh()


## Un clic su una cella: se c'è un'unità selezionata la sposta, altrimenti
## seleziona quella presente.
func _on_cell_pressed(cell: Vector2i) -> void:
	var p := player()
	if selected != null:
		if not p.move_to_board(selected, cell):
			_log("[color=#e0a070]Puoi schierare al massimo %d unità (livello %d).[/color]" % [p.max_board_units(), p.level])
		selected = null
	else:
		selected = p.unit_at_cell(cell)
	_refresh()


func _on_bench_slot_pressed(slot: int) -> void:
	var p := player()
	var occupant: UnitInstance = null
	for unit in p.bench_units():
		if unit.bench_slot == slot:
			occupant = unit
			break

	if selected != null:
		p.move_to_bench(selected, slot)
		selected = null
	else:
		selected = occupant
	_refresh()


# --------------------------------------------------------------------------
# Aggiornamento della vista
# --------------------------------------------------------------------------

func _refresh() -> void:
	var p := player()

	_round_label.text = "Round %s" % match_state.round_label()

	# I tre numeri caldi finiscono nelle chip, dove si leggono di sbieco senza
	# rileggere l'etichetta; quelli che si consultano e basta restano in riga.
	_hp_label.text = str(p.hp)
	_gold_label.text = str(p.gold)
	_level_label.text = "%d  (%d/%d)" % [p.level, p.xp, p.xp_to_next_level()]
	_stats_label.text = "%s    Unità %d/%d    Serie %+d" % [
		p.display_name, p.board_count(), p.max_board_units(), p.streak,
	]

	_sell_button.disabled = selected == null
	_sell_button.text = "Vendi · %d" % selected.sell_value() if selected != null else "Vendi"

	_refresh_shop()
	_refresh_board()
	_refresh_bench()
	_refresh_synergies()
	_refresh_ranking()


## Crea i controlli a numero fisso. Chiamata una sola volta, da _ready().
func _build_slot_buttons() -> void:
	var match_data: Dictionary = GameData.balance()["match"]

	for slot in int(match_data["shop_slots"]):
		var button := UnitSlot.new()
		button.custom_minimum_size = SHOP_SLOT_SIZE
		button.pressed.connect(_on_shop_slot_pressed.bind(slot))
		_shop_row.add_child(button)
		_shop_buttons.append(button)

	for y in int(match_data["board_rows"]):
		var row_box := HBoxContainer.new()
		row_box.add_theme_constant_override("separation", 0)
		_board_rows.add_child(row_box)
		# Lo sfalsamento delle righe dispari è uno spaziatore di mezza cella in
		# testa alla riga: le celle restano pulsanti normali, e resta il layout a
		# occuparsi delle dimensioni.
		if y % 2 == 1:
			var offset := Control.new()
			offset.custom_minimum_size = Vector2(CELL_SIZE.x * 0.5, 0)
			offset.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row_box.add_child(offset)
		for x in int(match_data["board_columns"]):
			var cell := Vector2i(x, y)
			var button := UnitSlot.new()
			button.hexagonal = true
			button.custom_minimum_size = CELL_SIZE
			button.pressed.connect(_on_cell_pressed.bind(cell))
			row_box.add_child(button)
			_cell_buttons[cell] = button

	for slot in int(match_data["bench_size"]):
		var button := UnitSlot.new()
		button.custom_minimum_size = BENCH_SLOT_SIZE
		button.pressed.connect(_on_bench_slot_pressed.bind(slot))
		_bench_row.add_child(button)
		_bench_buttons.append(button)

	# I ritratti si preparano subito: generarli mentre il giocatore compra
	# farebbe comparire le figure a scoppio ritardato.
	get_node("/root/Portraits").preload_units(_all_unit_ids())


func _all_unit_ids() -> Array:
	var ids: Array = []
	for def in GameData.all_units():
		ids.append(def.id)
	return ids


func _refresh_shop() -> void:
	var p := player()
	for slot in _shop_buttons.size():
		var button := _shop_buttons[slot]
		var def: UnitDef = p.shop[slot]
		if def == null:
			button.disabled = true
			button.show_empty(Style.CELL, Style.CELL)
			continue

		button.disabled = false

		# Il bordo dice la rarità, la figura dice civiltà e ruolo. Lo sfondo
		# schiarito segnala la civiltà preferita scelta nel menu — è l'unico
		# effetto di quella scelta, che resta un aiuto visivo e non un vantaggio.
		var favourite: bool = def.origin == String(_profile.favourite_origin)
		button.show_unit(
			def, 0, UnitSlot.Badge.COST,
			Style.PANEL.lightened(0.12) if favourite else Style.PANEL,
			Style.rarity_color(def.cost), 2, _unit_tooltip(def)
		)


func _refresh_board() -> void:
	var p := player()
	for cell in _cell_buttons:
		_style_unit_button(_cell_buttons[cell], p.unit_at_cell(cell), cell.y == 0)


func _refresh_bench() -> void:
	var p := player()
	var by_slot := {}
	for unit in p.bench_units():
		by_slot[unit.bench_slot] = unit

	for slot in _bench_buttons.size():
		_style_unit_button(_bench_buttons[slot], by_slot.get(slot))


## Aggiorna una casella che rappresenta una posizione: vuota o con un'unità.
func _style_unit_button(button: UnitSlot, unit: UnitInstance, front_line: bool = false) -> void:
	if unit == null:
		var empty_fill := Style.FRONT_LINE if front_line else Style.CELL
		button.show_empty(empty_fill, Style.CELL.lightened(0.06))
		return

	var border := Style.SELECTED if unit == selected else Style.rarity_color(unit.def.cost)
	button.show_unit(
		unit.def, unit.star, UnitSlot.Badge.STARS,
		Style.PANEL, border, 3 if unit == selected else 2, _unit_tooltip(unit.def)
	)


func _unit_tooltip(def: UnitDef) -> String:
	var traits: Array[String] = []
	for trait_id in def.traits():
		traits.append(GameData.trait_name(trait_id))

	var stats := def.base_stats
	return "%s (%d oro)\n%s\n\nSalute %d   Danno %d   Gittata %d\nVelocità d'attacco %.2f\nArmatura %d   Res. magica %d\n\n%s: %s" % [
		def.display_name, def.cost, ", ".join(traits),
		int(stats.get("hp", 0)), int(stats.get("attack_damage", 0)), int(stats.get("range", 1)),
		float(stats.get("attack_speed", 0.0)),
		int(stats.get("armor", 0)), int(stats.get("magic_resist", 0)),
		def.ability.get("name", "—"), def.ability.get("description", ""),
	]


func _log(text: String) -> void:
	_log_label.append_text(text + "\n")
