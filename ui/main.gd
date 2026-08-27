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
var _combat_overlay: Control
var _combat_controls: Control
var _info_sheet: Panel
var _synergy_detail: Control
var _synergy_detail_backdrop: ColorRect
var _synergy_detail_title: Label
var _synergy_detail_description: Label
var _synergy_detail_tiers: VBoxContainer
var _combat_view: CombatView
var _tips: TipBubble
var _combat_title: Label
var _combat_top_bar: HBoxContainer
var _combat_top_name: Label
var _combat_top_hp: Label
var _combat_top_synergy_row: HBoxContainer
var _combat_bottom_bar: HBoxContainer
var _combat_bottom_hp: Label
var _combat_bottom_synergy_row: HBoxContainer
var _combat_outcome: Label
var _continue_button: Button
var _exit_confirm: ConfirmationDialog
var _spectate_overlay: Panel
var _spectate_view: CombatView
var _spectate_title: Label
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


## Disattiva i suggerimenti one-shot: utile per gli screenshot e per chi
## vuole giocare senza interruzioni.
##
##   godot --path . -- --no-tips
func _tips_requested() -> bool:
	return "--no-tips" not in OS.get_cmdline_user_args()


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

	# Aggiorna ed esperienza affiancano la riga del negozio invece di stare
	# sotto: due pulsanti icona ai lati, con il costo nel tooltip invece che
	# scritto per esteso — libera spazio orizzontale per le caselle del
	# negozio, che sono ciò che si guarda per primo.
	var shop_row_wrap := HBoxContainer.new()
	shop_row_wrap.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	shop_row_wrap.add_theme_constant_override("separation", 6)
	body.add_child(shop_row_wrap)

	var buy_xp := _shop_icon_button(
		"📈", "Esperienza", int(GameData.balance()["economy"]["buy_xp_cost"]))
	buy_xp.pressed.connect(_on_buy_xp_pressed)
	shop_row_wrap.add_child(buy_xp)

	_shop_row = HBoxContainer.new()
	_shop_row.add_theme_constant_override("separation", 6)
	shop_row_wrap.add_child(_shop_row)

	var reroll := _shop_icon_button(
		"🔄", "Aggiorna", int(GameData.balance()["economy"]["reroll_cost"]))
	reroll.pressed.connect(_on_reroll_pressed)
	shop_row_wrap.add_child(reroll)

	# Nel flusso del layout, non come overlay ancorato: quando compare, spinge
	# la barra dei comandi verso il basso invece di coprire COMBATTI.
	_tips = TipBubble.new()
	_tips.enabled = _tips_requested()
	root.add_child(_tips)

	root.add_child(_build_action_bar())

	# Sovrapposizioni, dalla meno alla più invadente: l'ordine di aggiunta è
	# l'ordine di disegno, e la battaglia deve poter coprire tutto il resto.
	_build_info_sheet()

	_build_combat_overlay()
	_build_spectate_overlay()


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


## Pulsante icona ai lati della riga del negozio (aggiorna, esperienza): solo
## il glifo, come i pulsanti della barra d'azione — il costo resta consultabile
## nel tooltip invece di occupare spazio in riga. Il costo compare comunque
## anche scritto sul pulsante — con l'icona della moneta al posto della
## parola "oro" — così non serve tenere premuto per scoprirlo.
func _shop_icon_button(icon: String, action_label: String, cost: int) -> Button:
	var button := Button.new()
	button.text = "%s  %d⛁" % [icon, cost]
	button.tooltip_text = "%s · %d⛁" % [action_label, cost]
	button.custom_minimum_size = Vector2(84, 56)
	button.add_theme_font_size_override("font_size", 20)
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
	# Il pannello resta trasparente: il fondale è lo sfondo crepuscolare qui
	# sotto, non più il nero piatto di prima.
	_combat_overlay.add_theme_stylebox_override("panel", Style.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0))
	_combat_overlay.visible = false
	add_child(_combat_overlay)

	# Crepuscolo di battaglia: più scuro e più freddo del cielo del menu, con
	# un accenno di rosso in basso, così lo schermo segnala "si combatte" anche
	# prima di leggere una riga di testo.
	_combat_overlay.add_child(Style.backdrop(Color(0.02, 0.03, 0.07), Color(0.17, 0.05, 0.09)))

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

	box.add_child(_build_combat_top_bar())

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

	box.add_child(_build_combat_bottom_bar())

	_combat_outcome = Label.new()
	_combat_outcome.add_theme_font_size_override("font_size", 18)
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
	_continue_button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	_continue_button.add_theme_font_size_override("font_size", 22)
	_continue_button.add_theme_color_override("font_color", Style.INK)
	_continue_button.add_theme_color_override("font_hover_color", Style.INK)
	_continue_button.add_theme_color_override("font_pressed_color", Style.INK)
	Style.apply_plate(_continue_button, Style.GOLD, Style.GOLD_DEEP, 20, 8)
	_continue_button.visible = false
	_continue_button.pressed.connect(_on_continue_pressed)
	box.add_child(_continue_button)

	_combat_controls = controls


## Riga in alto: chi si sta affrontando in questo round, la sua vita e le sue
## sinergie attive — le stesse informazioni che in fase di preparazione si
## leggono aprendo la classifica avversari, qui a colpo d'occhio mentre si
## guarda la battaglia.
func _build_combat_top_bar() -> Control:
	_combat_top_bar = HBoxContainer.new()
	_combat_top_bar.add_theme_constant_override("separation", 8)

	_combat_top_name = Label.new()
	_combat_top_name.add_theme_font_size_override("font_size", 15)
	_combat_top_name.add_theme_color_override("font_color", Style.TEXT_DIM)
	_combat_top_name.clip_text = true
	_combat_top_bar.add_child(_combat_top_name)

	_combat_top_hp = Label.new()
	_combat_top_hp.add_theme_font_size_override("font_size", 15)
	_combat_top_hp.add_theme_color_override("font_color", Color(0.92, 0.45, 0.42))
	_combat_top_bar.add_child(_combat_top_hp)

	_combat_top_synergy_row = HBoxContainer.new()
	_combat_top_synergy_row.add_theme_constant_override("separation", 4)
	_combat_top_synergy_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_combat_top_bar.add_child(_combat_top_synergy_row)

	return _combat_top_bar


## Riga in basso: le stesse informazioni ma per la propria squadra — la vita
## che si sta rischiando in questo round e le sinergie che la stanno
## sostenendo, senza dover uscire dalla battaglia per ricordarsele.
func _build_combat_bottom_bar() -> Control:
	_combat_bottom_bar = HBoxContainer.new()
	_combat_bottom_bar.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = "Tu"
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Style.TEXT_DIM)
	_combat_bottom_bar.add_child(label)

	_combat_bottom_hp = Label.new()
	_combat_bottom_hp.add_theme_font_size_override("font_size", 15)
	_combat_bottom_hp.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5))
	_combat_bottom_bar.add_child(_combat_bottom_hp)

	_combat_bottom_synergy_row = HBoxContainer.new()
	_combat_bottom_synergy_row.add_theme_constant_override("separation", 4)
	_combat_bottom_synergy_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_combat_bottom_bar.add_child(_combat_bottom_synergy_row)

	return _combat_bottom_bar


## Ripopola le due barre a ogni round: chiamata da _show_combat() con lo
## stesso dizionario "own" restituito da resolve_round(). Un round fantasma
## (own["opponent"] == null) nasconde la barra dell'avversario invece di
## leggere campi che non esistono.
func _refresh_combat_info(own: Dictionary) -> void:
	var opponent: Player = own.get("opponent")
	if opponent == null:
		_combat_top_bar.visible = false
	else:
		_combat_top_bar.visible = true
		_combat_top_name.text = opponent.display_name
		_combat_top_hp.text = "❤ %d" % opponent.hp
		_refresh_combat_synergy_row(_combat_top_synergy_row, opponent.board_units())

	_combat_bottom_hp.text = "❤ %d" % player().hp
	_refresh_combat_synergy_row(_combat_bottom_synergy_row, player().board_units())


func _refresh_combat_synergy_row(row: HBoxContainer, units: Array) -> void:
	for child in row.get_children():
		child.queue_free()
	for synergy_row in TraitResolver.summary(units):
		if bool(synergy_row["active"]):
			row.add_child(_combat_chip(synergy_row))


## Versione compatta e non interattiva di _synergy_chip(), per le barre della
## schermata di battaglia: qui serve solo leggere a colpo d'occhio, non aprire
## il dettaglio — e il riquadro non ha spazio per pulsanti a grandezza piena.
func _combat_chip(row: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var tint: Color = Style.origin_color(String(row["id"])) if bool(row["is_origin"]) else Style.BLUE
	panel.add_theme_stylebox_override("panel", Style.plate(tint.darkened(0.55), tint, 8, 3))

	var label := Label.new()
	label.text = "● %s" % row["name"]
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", tint.lightened(0.35))
	panel.add_child(label)

	return panel


## Overlay per rivedere solo lo schieramento iniziale dell'ultimo combattimento
## di un avversario: niente pulsanti di velocità o "continua", perché non c'è
## una battaglia da riprodurre né un round da concludere — è solo un'occhiata
## a come si è schierato, per copiare o correggere la propria formazione.
## Un CombatView separato da quello della propria battaglia: condividere lo
## stesso avrebbe richiesto salvare e ripristinare lo stato del round in corso
## ogni volta che si apre e si chiude, per un semplice sguardo a un tabellone.
func _build_spectate_overlay() -> void:
	_spectate_overlay = Panel.new()
	_spectate_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_spectate_overlay.add_theme_stylebox_override("panel", Style.box(Style.INK, Style.INK, 0, 0))
	_spectate_overlay.visible = false
	add_child(_spectate_overlay)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	_spectate_overlay.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	_spectate_title = Label.new()
	_spectate_title.add_theme_font_size_override("font_size", 24)
	_spectate_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_spectate_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_spectate_title)

	_spectate_view = CombatView.new()
	_spectate_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spectate_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_spectate_view)

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 24)
	Style.apply_plate(close, Style.PLATE, Style.PLATE_DARK, 16, 5)
	close.pressed.connect(func() -> void: _spectate_overlay.visible = false)
	box.add_child(close)


## Mostra lo schieramento iniziale dell'ultimo combattimento di `pl`, fermo
## (nessuna chiamata a play()): l'utente ha chiesto di vedere dove ha piazzato
## le unità, non di rivedere la battaglia intera. Se l'avversario non ha
## ancora combattuto in questa partita, o il suo ultimo round è stato un
## fantasma senza schieramento, il tocco non fa nulla: non c'è niente da
## mostrare.
func _open_spectate(pl: Player) -> void:
	var result := {}
	for entry in match_state.last_results():
		if entry["player"] == pl:
			result = entry
			break
	if result.is_empty() or bool(result.get("ghost", false)) or result["combat"].is_empty():
		return

	var opponent: Player = result.get("opponent")
	_spectate_title.text = "Ultimo schieramento — %s" % pl.display_name
	_spectate_view.set_hero_portraits(pl.hero_id, opponent.hero_id if opponent != null else "")
	_spectate_view.load_combat(result["combat"], int(result.get("team", 0)))
	_spectate_overlay.visible = true


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
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
		# La riga tocca per rivedere l'ultimo schieramento di quell'avversario.
		# I figli ignorano il mouse, così il clic arriva sempre al pulsante che
		# li contiene (come in UnitSlot). Non più `flat`: senza uno stato hover
		# e pressed la riga non sembra toccabile: una piastra minima —
		# trasparente da ferma, appena illuminata al passaggio, incassata da
		# premuta — dà l'affordance senza rubare spazio nel riquadro stretto.
		var row := Button.new()
		row.custom_minimum_size = Vector2(0, Style.TOUCH_MIN * 0.4)
		row.tooltip_text = "Rivedi lo schieramento di %s" % pl.display_name
		_style_ranking_row(row)
		row.pressed.connect(_open_spectate.bind(pl))
		_ranking_list.add_child(row)

		var inner := HBoxContainer.new()
		inner.add_theme_constant_override("separation", 6)
		inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(inner)

		var name_label := Label.new()
		name_label.text = pl.display_name
		name_label.add_theme_font_size_override("font_size", 15)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(name_label)

		var hp_label := Label.new()
		hp_label.add_theme_font_size_override("font_size", 15)
		hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(hp_label)

		# Lente in coda: segnala che la riga apre un dettaglio, senza dover
		# leggere il tooltip (assente su touch).
		var peek := Label.new()
		peek.text = "🔍"
		peek.add_theme_font_size_override("font_size", 13)
		peek.add_theme_color_override("font_color", Style.TEXT_DIM)
		peek.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(peek)

		if pl.eliminated or pl.hp <= 0:
			hp_label.text = "☠"
			name_label.add_theme_color_override("font_color", Style.TEXT_DIM)
			hp_label.add_theme_color_override("font_color", Style.TEXT_DIM)
		else:
			hp_label.text = str(pl.hp)
			hp_label.add_theme_color_override("font_color", Color(0.92, 0.45, 0.45))


## Piastra minima per le righe della classifica avversari: trasparente da
## ferma per non appesantire il riquadro, un velo chiaro al passaggio del
## mouse e una faccia incassata da premuta — lo stesso linguaggio di
## Style.apply_plate ma con margini ridotti, perché la riga è alta poche
## decine di pixel e larga 150.
func _style_ranking_row(row: Button) -> void:
	var clear := Style.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 6)
	clear.content_margin_left = 6
	clear.content_margin_right = 6
	clear.content_margin_top = 3
	clear.content_margin_bottom = 3
	var hover := clear.duplicate() as StyleBoxFlat
	hover.bg_color = Style.PLATE.lightened(0.06)
	hover.border_color = Style.PLATE.lightened(0.25)
	hover.set_border_width_all(1)
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = Style.PLATE_DARK
	row.add_theme_stylebox_override("normal", clear)
	row.add_theme_stylebox_override("hover", hover)
	row.add_theme_stylebox_override("pressed", pressed)
	row.add_theme_stylebox_override("focus", clear)


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

	var any_active := false
	for row in rows:
		_synergy_row.add_child(_synergy_chip(row))
		if bool(row["active"]):
			any_active = true
	if any_active:
		_tips.queue_tip("synergy")


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
##
## A differenza del foglio informazioni e della battaglia, questo è un
## dettaglio breve: un modale piccolo e centrato, non un pannello a schermo
## intero, con uno sfondo attenuato dietro (gemello, non genitore — così
## resta un semplice rettangolo da mostrare/nascondere insieme al modale,
## senza dover gestire il centraggio anche al suo interno).
func _build_synergy_detail() -> void:
	_synergy_detail_backdrop = ColorRect.new()
	_synergy_detail_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_synergy_detail_backdrop.color = Color(0, 0, 0, 0.55)
	_synergy_detail_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_synergy_detail_backdrop.visible = false
	add_child(_synergy_detail_backdrop)

	# Un CenterContainer a tutto schermo, trasparente e che ignora il mouse
	# fuori dal figlio, tiene il modale in mezzo qualunque sia la sua altezza
	# di contenuto — senza dover calcolare offset a mano come per i pannelli
	# a tutto schermo.
	_synergy_detail = CenterContainer.new()
	_synergy_detail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_synergy_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_synergy_detail.visible = false
	add_child(_synergy_detail)

	var dialog := PanelContainer.new()
	dialog.custom_minimum_size = Vector2(420, 0)
	dialog.add_theme_stylebox_override("panel", Style.plate(Style.PLATE, Style.GOLD_DEEP, 18, 6))
	_synergy_detail.add_child(dialog)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	dialog.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	_synergy_detail_title = Label.new()
	_synergy_detail_title.add_theme_font_size_override("font_size", 24)
	_synergy_detail_title.add_theme_color_override("font_color", Style.GOLD)
	_synergy_detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_synergy_detail_title)

	_synergy_detail_description = Label.new()
	_synergy_detail_description.add_theme_font_size_override("font_size", 16)
	_synergy_detail_description.add_theme_color_override("font_color", Style.TEXT_DIM)
	_synergy_detail_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_synergy_detail_description)

	# Altezza limitata invece di SIZE_EXPAND_FILL: dentro un CenterContainer
	# nessun genitore impone un'altezza massima, quindi senza un tetto la
	# lista delle soglie spingerebbe il modale fuori dallo schermo su una
	# sinergia con molti livelli.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 260)
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
	close.pressed.connect(_close_synergy_detail)
	column.add_child(close)


func _close_synergy_detail() -> void:
	_synergy_detail.visible = false
	_synergy_detail_backdrop.visible = false


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

	_synergy_detail_backdrop.visible = true
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
	_spectate_overlay.visible = false
	_pending_results = []
	_fight_button.text = "COMBATTI"
	selected = null

	match_state = MatchState.new(_requested_seed(), 1)
	match_state.human_player().hero_id = _profile.effective_hero()
	brains.clear()
	var brain_rng := SimRNG.new(match_state.seed_value ^ 0x5EED)
	for p in match_state.players:
		if p.is_bot:
			brains.append(BotBrain.new(p, brain_rng.fork(p.index)))

	_log("[b]Nuova partita[/b] (seed %d)" % match_state.seed_value)
	_log("Civiltà disponibili: %s" % ", ".join(_store.playable_origins()))
	match_state.start_round()
	_refresh()
	_tips.queue_tip("shop")


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
	_refresh_combat_info(own)
	_combat_outcome.text = ""
	_continue_button.visible = false
	_combat_controls.visible = true

	_combat_view.speed = float(_profile.combat_speed)
	_combat_view.set_hero_portraits(player().hero_id, opponent.hero_id if opponent != null else "")
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
		_combat_outcome.text = "Vittoria — %d danni all'avversario" % int(own["damage_dealt"])
		_combat_outcome.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5))
	else:
		_combat_outcome.text = "Sconfitta — %d danni alla tua vita" % int(own["damage"])
		_combat_outcome.add_theme_color_override("font_color", Color(0.9, 0.45, 0.45))
	_continue_button.visible = true
	_combat_controls.visible = false
	_tips.queue_tip("combat")
	# Vista la prima battaglia, il giocatore ha un motivo concreto per aprire il
	# riquadro AVVERSARI: spiegargli che le righe sono toccabili.
	_tips.queue_tip("ranking")
	if own.get("opponent") != null and not bool(own.get("ghost", false)):
		_combat_view.show_result_beam(bool(own["won"]), int(own["damage_dealt"] if bool(own["won"]) else own["damage"]))


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
		# round_index è già stato fatto avanzare da resolve_round(): stage 1,
		# round 2 è il primo round che il giocatore sta per affrontare dopo
		# aver visto un round intero di economia in azione.
		if match_state.stage == 1 and match_state.round_index == 2:
			_tips.queue_tip("economy")
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
			_log("  [color=#7fd67f]Vittoria[/color] contro %s (−%d vita avversario)" % [opponent_name, int(result["damage_dealt"])])
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
	_tips.queue_tip("bench")
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
		if selected != null:
			_tips.queue_tip("board")
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

	for unit in p.board_units() + p.bench_units():
		if unit.star >= 2:
			_tips.queue_tip("star")
			break


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
