extends Control

## Schermata iniziale. È la scena principale del progetto: da qui si entra in
## partita, e la partita può tornare qui.
##
## Tenerla separata da ui/main.tscn — invece di sovrapporre l'ennesimo pannello
## — significa che iniziare una partita ricrea sempre uno stato pulito: nessun
## residuo del round precedente può sopravvivere a un cambio di scena.
##
## Il layout è pensato per il portrait 720×1280. La home è a schede: cinque
## pagine affiancate (Negozio, Collezione, Battaglia, Guida, Cronologia) che
## scorrono in orizzontale, e una barra fissa in basso per sceglierle — oltre
## allo swipe. Battaglia è la scheda di partenza e l'unica da cui si entra in
## partita. Nessun bersaglio tattile sotto Style.TOUCH_MIN.

const GAME_SCENE := "res://ui/main.tscn"
const LOBBY_SCENE := "res://ui/lobby.tscn"

const MODE_CPU := "cpu"
const MODE_PVP := "pvp"

const TAB_STORE := 0
const TAB_COLLECTION := 1
const TAB_BATTLE := 2
const TAB_GUIDE := 3
const TAB_HISTORY := 4
const TAB_COUNT := 5

## Altezza della barra delle schede, sopra l'eventuale barra dei gesti: icona
## più etichetta su due righe, e mai sotto il minimo tattile.
const TAB_BAR_HEIGHT := 112
## La scheda Battaglia sporge sopra la barra: è il cuore della home anche
## quando si sta guardando un'altra pagina.
const TAB_CENTER_RAISE := 18
const PAGE_SLIDE_SECONDS := 0.3
## Spostamento orizzontale minimo perché un trascinamento conti come swipe, e
## rapporto minimo orizzontale/verticale: sotto, è uno scroll verticale.
const SWIPE_MIN_PX := 90.0
const SWIPE_AXIS_RATIO := 1.6


## Vetrina 3D dell'eroe in cima alla schermata: stesse proporzioni della
## scheda unità in collezione, ma qui il modello è vivo e ruotabile a
## trascinamento invece che una posa fissa.
const HERO_VIEW_SIZE := 480
const HERO_CAMERA_OFFSET := Vector3(0, 1.35, 2.35)
const HERO_ZOOM := 1.5
## Un giro completo ogni 24 secondi, come nella scheda di dettaglio.
const HERO_AUTO_ROTATE_SPEED := TAU / 24.0

## Vetrina 3D della scheda di dettaglio eroe: stessa impostazione di quella in
## home. La modale è ancorata all'84% dello schermo (_build_small_modal), con
## nome/civiltà/testo che occupano una piccola parte di quello spazio: il
## modello può prendersi la parte grande senza spingere via nulla.
const HERO_DETAIL_VIEW_SIZE := 400
const HERO_DETAIL_CAMERA_OFFSET := Vector3(0, 1.35, 2.35)
## Più largo di quanto l'altezza da sola richieda, come in collezione: un
## eroe che tiene un'arma di traverso può sporgere più largo che alto quando
## ruota, e uscire dall'inquadratura.
const HERO_DETAIL_ZOOM := 1.9
## Un giro completo ogni 24 secondi, come nella scheda unità in collezione.
const HERO_DETAIL_AUTO_ROTATE_SPEED := TAU / 24.0

## Gli autoload si prendono dall'albero e non per nome globale: gli script
## compilati da riga di comando (test headless) non li vedrebbero.
var _store: Node
var _profile: Node
var _store_panel: StorePanel
var _collection_panel: CollectionPanel
var _history_panel: HistoryPanel
var _leaderboard_panel: LeaderboardPanel
var _guide_panel: GuidePanel
var _settings_panel: SettingsPanel
var _mode_panel: Panel
var _mode_button: Button
var _mode_option_buttons: Dictionary = {}
var _match_mode: String = MODE_CPU

## Grado online (mmr) di chi ha fatto login. Assente per chi gioca da ospite —
## l'mmr esiste solo per un account, calcolato server-side dopo ogni partita
## classificata (db/migrations/0002_rank_mmr.sql).
var _rank_label: Label

## Pager: _pages_clip ritaglia, _pages_strip è la fila delle cinque pagine
## affiancate che scorre in x. _pages è indicizzato con le costanti TAB_*.
var _current_tab := TAB_BATTLE
var _pages_clip: Control
var _pages_strip: Control
var _pages: Array[Control] = []
var _tab_buttons: Array[Button] = []
var _tab_indicator: ColorRect
var _page_tween: Tween
var _indicator_tween: Tween
var _swipe_start := Vector2.ZERO
var _swipe_tracking := false
## Zone in cui un trascinamento orizzontale ha già un significato (ruotare
## l'eroe, scorrere i filtri della collezione): lì non si cambia pagina.
var _swipe_blockers: Array[Control] = []

var _history_toggle_matches: Button
var _history_toggle_leaderboard: Button

## Colonna con tutto il contenuto e spaziatore elastico in cima: dentro uno
## ScrollContainer SIZE_EXPAND_FILL non basta più da solo (il contenitore
## dimensiona il figlio al suo minimo, non riempie lo spazio), quindi
## _apply_layout() calcola a mano quanto vuoto avanzare al suo interno.
var _content_column: VBoxContainer
var _content_scroll: ScrollContainer
var _grow_spacer: Control

var _hero_panel: Panel
var _hero_button: Button
var _hero_option_buttons: Dictionary = {}
var _hero_name_label: Label
var _selected_hero: String = ""

## Vetrina 3D viva dell'eroe: viewport, camera e nodo su cui appendere il
## modello corrente, più lo stato del trascinamento che lo fa ruotare.
var _hero_viewport: SubViewport
var _hero_camera: Camera3D
var _hero_model_root: Node3D
var _hero_dragging := false
var _hero_drag_last_x := 0.0
## Vero finché il giocatore non tocca il modello in home: si spegne al primo
## drag, come nella scheda di dettaglio.
var _hero_auto_rotating := true

var _hero_detail_panel: Panel
var _hero_detail_id: String = ""
var _hero_detail_viewport: SubViewport
var _hero_detail_camera: Camera3D
var _hero_detail_model_root: Node3D
var _hero_detail_dragging := false
var _hero_detail_drag_last_x := 0.0
## Vero finché il giocatore non tocca il modello: si spegne al primo drag e
## resta spento per quell'eroe (si riaccende aprendone un altro).
var _hero_detail_auto_rotating := true
var _hero_detail_name: Label
var _hero_detail_origin: Label
var _hero_detail_lore: Label
var _hero_detail_ability: Label
var _hero_detail_select: Button


func _process(delta: float) -> void:
	if _hero_auto_rotating and _hero_model_root != null:
		_hero_model_root.rotate_y(HERO_AUTO_ROTATE_SPEED * delta)
	if _hero_detail_auto_rotating and _hero_detail_panel != null and _hero_detail_panel.visible \
			and _hero_detail_model_root != null:
		_hero_detail_model_root.rotate_y(HERO_DETAIL_AUTO_ROTATE_SPEED * delta)


func _ready() -> void:
	GameData.ensure_loaded()
	_store = get_node("/root/Store")
	_profile = get_node("/root/Profile")
	_selected_hero = _profile.effective_hero()
	var _music := get_node_or_null("/root/Music")
	if _music != null:
		_music.play_general()
	_match_mode = _restored_mode()
	_build()
	_apply_layout()
	_refresh_rank_label()
	var auth := get_node_or_null("/root/Auth")
	if auth != null:
		# Copre sia il login fatto da qui (bottone PVP) sia il rientro al menu
		# dopo un login gia' avvenuto: _ready() da solo vedrebbe Auth.stats solo
		# se il login e' concluso PRIMA che questa scena si costruisca.
		auth.login_completed.connect(func(_ok: bool, _reason: String) -> void: _refresh_rank_label())

	# I ritratti 3D si generano un fotogramma per unità: farlo qui, mentre il
	# giocatore guarda il menu, fa sì che collezione e partita li trovino già
	# pronti invece di vederli comparire a uno a uno.
	var ids: Array = []
	for def in GameData.all_units():
		ids.append(def.id)
	var portraits := get_node("/root/Portraits")
	portraits.preload_units(ids)
	portraits.preload_heroes(GameData.hero_ids())
	_refresh_hero_model()


# --------------------------------------------------------------------------
# Costruzione
# --------------------------------------------------------------------------

func _build() -> void:
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))
	var bar_height := TAB_BAR_HEIGHT + Style.safe_bottom_inset()

	_pages_clip = Control.new()
	_pages_clip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pages_clip.offset_bottom = -bar_height
	# Senza ritaglio le pagine vicine si vedrebbero ai lati durante lo
	# scorrimento, e riceverebbero i tocchi fuori dallo schermo.
	_pages_clip.clip_contents = true
	_pages_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_pages_clip)

	_pages_strip = Control.new()
	_pages_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pages_clip.add_child(_pages_strip)

	_store_panel = StorePanel.new()
	_store_panel.embedded = true
	_collection_panel = CollectionPanel.new()
	_collection_panel.embedded = true
	_guide_panel = GuidePanel.new()
	_guide_panel.embedded = true

	# Stesso ordine delle costanti TAB_*.
	_add_page(_build_panel_page(_store_panel))
	_add_page(_build_panel_page(_collection_panel))
	_add_page(_build_battle_page())
	_add_page(_build_panel_page(_guide_panel))
	_add_page(_build_history_page())
	_swipe_blockers.append(_collection_panel.filter_scroll)

	add_child(_build_tab_bar(bar_height))

	# Tutto ciò che segue sta sopra pagine e barra: le modali le coprono.
	_settings_panel = SettingsPanel.new()
	add_child(_settings_panel)

	_build_mode_panel()
	_update_mode_button()
	_build_hero_panel()
	_build_hero_detail_panel()
	_update_hero_button()

	_pages_clip.resized.connect(_layout_pages)
	_layout_pages()
	select_tab(TAB_BATTLE, false)


func _add_page(page: Control) -> void:
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pages_strip.add_child(page)
	_pages.append(page)


## Una pagina che è un pannello esistente in modalità incorporata: il pannello
## si ancora da solo a tutta la pagina nel suo _ready().
func _build_panel_page(panel: Panel) -> Control:
	var page := Control.new()
	page.add_child(panel)
	return page


## La home vera e propria: castello, eroe, grado e BATTAGLIA.
func _build_battle_page() -> Control:
	var page := Control.new()
	page.add_child(CastleBackdrop.new())

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Il contenuto comincia dove finisce la pietra: colonne e arco sono
	# architettura, e nulla ci deve salire sopra, altrimenti tornano a essere
	# decorazione dietro al testo.
	margin.add_theme_constant_override("margin_left", int(CastleBackdrop.COLUMN_W) + 14)
	margin.add_theme_constant_override("margin_right", int(CastleBackdrop.COLUMN_W) + 14)
	margin.add_theme_constant_override("margin_top", int(CastleBackdrop.SPRING_Y) + 16)
	margin.add_theme_constant_override("margin_bottom", int(CastleBackdrop.FLOOR_H) + 6)
	page.add_child(margin)

	# Su schermi bassi il contenuto non ci sta tutto in una volta: scorrimento
	# solo verticale come rete di sicurezza, la larghezza resta quella della
	# colonna.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	margin.add_child(scroll)
	_content_scroll = scroll

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)
	_content_column = column

	# Il titolo è ancorato in alto, appena sotto l'arco: se galleggiasse su uno
	# spaziatore elastico si staccherebbe dalla cornice su ogni schermo diverso.
	column.add_child(_banner())
	_grow_spacer = _grow()
	column.add_child(_grow_spacer)
	column.add_child(_hero_display())
	_rank_label = _rank_readout()
	column.add_child(_rank_label)
	column.add_child(_battle_row())

	# Impostazioni: un'icona nell'angolo, non una scheda — si aprono di rado.
	var settings_button := Button.new()
	settings_button.text = "⚙️"
	settings_button.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(settings_button, Style.PLATE, Style.PLATE_DARK, 18, 6)
	settings_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	settings_button.offset_right = -12
	settings_button.offset_left = -12 - Style.TOUCH_MIN
	settings_button.offset_top = Style.safe_top_margin(12)
	settings_button.offset_bottom = settings_button.offset_top + Style.TOUCH_MIN
	settings_button.pressed.connect(func() -> void: _settings_panel.open())
	page.add_child(settings_button)

	return page


## Cronologia e classifica condividono la pagina: un selettore a due segmenti
## in cima sceglie quale dei due pannelli mostrare.
func _build_history_page() -> Control:
	var page := Control.new()
	page.add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 0)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(column)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", Style.safe_top_margin())
	margin.add_theme_constant_override("margin_bottom", 0)
	column.add_child(margin)

	var toggle := HBoxContainer.new()
	toggle.add_theme_constant_override("separation", 10)
	margin.add_child(toggle)

	_history_toggle_matches = Button.new()
	_history_toggle_matches.text = "📜 " + tr("MENU_HISTORY")
	_history_toggle_leaderboard = Button.new()
	_history_toggle_leaderboard.text = "🏆 " + tr("MENU_LEADERBOARD")
	for button: Button in [_history_toggle_matches, _history_toggle_leaderboard]:
		button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 20)
		toggle.add_child(button)
	_history_toggle_matches.pressed.connect(func() -> void: _show_history_section(false))
	_history_toggle_leaderboard.pressed.connect(func() -> void: _show_history_section(true))

	var body := Control.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(body)

	_history_panel = HistoryPanel.new()
	_history_panel.embedded = true
	body.add_child(_history_panel)
	_leaderboard_panel = LeaderboardPanel.new()
	_leaderboard_panel.embedded = true
	body.add_child(_leaderboard_panel)
	_show_history_section(false, false)

	return page


func _build_tab_bar(bar_height: int) -> Control:
	var bar := Control.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -bar_height
	bar.offset_bottom = 0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var background := Panel.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var style := Style.box(Style.STONE_DARK, Style.GOLD_DEEP, 0, 0)
	style.border_width_top = 3
	background.add_theme_stylebox_override("panel", style)
	bar.add_child(background)

	# La fila sale di TAB_CENTER_RAISE sopra la barra: solo la scheda centrale
	# è abbastanza alta da occupare quello spazio, le altre stanno in basso.
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 6
	row.offset_right = -6
	row.offset_top = -TAB_CENTER_RAISE
	row.offset_bottom = -Style.safe_bottom_inset() - 4
	row.add_theme_constant_override("separation", 4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(row)

	row.add_child(_tab_button(TAB_STORE, "🛒", "MENU_STORE"))
	row.add_child(_tab_button(TAB_COLLECTION, "🎴", "MENU_COLLECTION"))
	row.add_child(_tab_button(TAB_BATTLE, "⚔️", "MENU_TAB_BATTLE"))
	row.add_child(_tab_button(TAB_GUIDE, "📖", "MENU_GUIDE"))
	row.add_child(_tab_button(TAB_HISTORY, "📜", "MENU_HISTORY"))

	# Filo d'oro che scivola sopra la scheda attiva insieme alle pagine: dice
	# da dove si arriva e dove si va.
	_tab_indicator = ColorRect.new()
	_tab_indicator.color = Style.GOLD
	_tab_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_indicator.size = Vector2(0, 5)
	bar.add_child(_tab_indicator)
	row.sort_children.connect(func() -> void: _move_tab_indicator(false))

	return bar


func _tab_button(index: int, icon: String, label_key: String) -> Button:
	var button := Button.new()
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.size_flags_stretch_ratio = 1.15 if index == TAB_BATTLE else 1.0
	button.size_flags_vertical = Control.SIZE_SHRINK_END
	var height := TAB_BAR_HEIGHT - 8 + (TAB_CENTER_RAISE if index == TAB_BATTLE else 0)
	button.custom_minimum_size = Vector2(0, maxi(height, Style.TOUCH_MIN))
	button.tooltip_text = tr(label_key)
	button.pressed.connect(func() -> void: select_tab(index))

	# Icona e nome come etichette dentro al pulsante: nel testo del Button
	# l'emoji verrebbe della stessa taglia del nome, cioè illeggibile. Le
	# etichette ignorano il mouse, quindi il tocco resta tutto del pulsante.
	var stack := VBoxContainer.new()
	stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 0)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(stack)

	var icon_label := Label.new()
	icon_label.name = "Icon"
	icon_label.text = icon
	icon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_label.add_theme_font_size_override("font_size", 34 if index == TAB_BATTLE else 30)
	icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(icon_label)

	var name_label := Label.new()
	name_label.name = "Name"
	name_label.text = tr(label_key)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.add_theme_font_size_override("font_size", 18 if index == TAB_BATTLE else 16)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(name_label)

	_tab_buttons.append(button)
	return button


## Posizioni delle pagine dalla larghezza reale del ritaglio. Un resize non
## anima nulla: rimette la fila esattamente sulla pagina corrente.
func _layout_pages() -> void:
	if _pages_clip == null:
		return
	var page_size := _pages_clip.size
	for i in _pages.size():
		_pages[i].position = Vector2(i * page_size.x, 0)
		_pages[i].size = page_size
	_pages_strip.size = Vector2(TAB_COUNT * page_size.x, page_size.y)
	if _page_tween != null and _page_tween.is_valid():
		_page_tween.kill()
	_pages_strip.position = Vector2(-_current_tab * page_size.x, 0)
	_move_tab_indicator(false)
	_apply_layout()


## Cambia scheda facendo scorrere la fila delle pagine. La direzione viene dal
## segno della differenza: una scheda a destra entra da destra, e viceversa.
func select_tab(index: int, animate: bool = true) -> void:
	index = clampi(index, 0, TAB_COUNT - 1)
	if index == _current_tab and animate:
		return
	var previous := _current_tab
	_current_tab = index
	if previous == TAB_COLLECTION and index != TAB_COLLECTION:
		_collection_panel._detail_sheet.visible = false

	var target_x := -index * _pages_clip.size.x
	if _page_tween != null and _page_tween.is_valid():
		_page_tween.kill()
	if animate and is_inside_tree():
		# Durante lo scorrimento si vedono sia la pagina di partenza sia quella
		# d'arrivo: il rendering dell'eroe si spegne solo a scorrimento finito.
		_set_hero_rendering(true)
		_page_tween = create_tween()
		_page_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_page_tween.tween_property(_pages_strip, "position:x", target_x, PAGE_SLIDE_SECONDS)
		_page_tween.finished.connect(func() -> void: _set_hero_rendering(_current_tab == TAB_BATTLE))
	else:
		_pages_strip.position.x = target_x
		_set_hero_rendering(index == TAB_BATTLE)

	_on_tab_activated(index)
	_update_tab_buttons()
	_move_tab_indicator(animate)


func _set_hero_rendering(on: bool) -> void:
	if _hero_viewport != null:
		_hero_viewport.render_target_update_mode = \
				SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED


func _on_tab_activated(index: int) -> void:
	match index:
		TAB_STORE:
			_store_panel.open()
		TAB_COLLECTION:
			_collection_panel.open()
		TAB_GUIDE:
			_guide_panel.open()
		TAB_HISTORY:
			_show_history_section(_leaderboard_panel.visible)


func _show_history_section(leaderboard: bool, open_panel: bool = true) -> void:
	_history_panel.visible = not leaderboard
	_leaderboard_panel.visible = leaderboard
	if open_panel:
		if leaderboard:
			_leaderboard_panel.open()
		else:
			_history_panel.open()
	for pair in [[_history_toggle_matches, not leaderboard], [_history_toggle_leaderboard, leaderboard]]:
		var button: Button = pair[0]
		var active: bool = pair[1]
		Style.apply_plate(button, Style.GOLD if active else Style.PLATE, Style.GOLD_DEEP if active else Style.PLATE_DARK, 18, 6)
		_set_font_color(button, Style.INK if active else Style.TEXT_DIM)


## Scheda attiva dorata. La Guida, finché non è mai stata aperta, resta blu con
## nome d'oro e un punto: richiama l'occhio senza sembrare già selezionata.
func _update_tab_buttons() -> void:
	var guide_unseen: bool = not _profile.has_seen_tip("guide_opened")
	for i in _tab_buttons.size():
		var button := _tab_buttons[i]
		var name_label := button.find_child("Name", true, false) as Label
		var text := name_label.text.trim_prefix("• ")
		var color := Style.TEXT_DIM
		if i == _current_tab:
			Style.apply_plate(button, Style.GOLD, Style.GOLD_DEEP, 16, 6)
			color = Style.INK
		elif i == TAB_GUIDE and guide_unseen:
			Style.apply_plate(button, Style.BLUE, Style.BLUE_DEEP, 16, 6)
			color = Style.GOLD
			text = "• " + text
		elif i == TAB_BATTLE:
			Style.apply_plate(button, Style.STONE, Style.GOLD_DEEP, 16, 6)
			color = Style.GOLD
		else:
			Style.apply_plate(button, Style.PLATE, Style.PLATE_DARK, 16, 6)
		name_label.text = text
		name_label.add_theme_color_override("font_color", color)


func _set_font_color(button: Button, color: Color) -> void:
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(key, color)


func _move_tab_indicator(animate: bool) -> void:
	if _tab_indicator == null or _current_tab >= _tab_buttons.size():
		return
	var button := _tab_buttons[_current_tab]
	var bar := _tab_indicator.get_parent() as Control
	var target := Vector2(button.global_position.x - bar.global_position.x + 14,
			button.global_position.y - bar.global_position.y - 9)
	var width := maxf(0.0, button.size.x - 28)
	if _indicator_tween != null and _indicator_tween.is_valid():
		_indicator_tween.kill()
	if animate and is_inside_tree():
		_indicator_tween = create_tween().set_parallel(true)
		_indicator_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_indicator_tween.tween_property(_tab_indicator, "position", target, PAGE_SLIDE_SECONDS)
		_indicator_tween.tween_property(_tab_indicator, "size:x", width, PAGE_SLIDE_SECONDS)
	else:
		_tab_indicator.position = target
		_tab_indicator.size.x = width


## Swipe: si osserva e basta, senza consumare l'evento — un tocco breve deve
## arrivare comunque ai pulsanti, uno verticale agli scroll. Sul telefono il
## tocco arriva anche come mouse emulato: basta ascoltare quello.
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		_swipe_tracking = _swipe_allowed_at(mb.position)
		_swipe_start = mb.position
		return
	if not _swipe_tracking:
		return
	_swipe_tracking = false
	var d := mb.position - _swipe_start
	if absf(d.x) >= SWIPE_MIN_PX and absf(d.x) >= absf(d.y) * SWIPE_AXIS_RATIO:
		select_tab(_current_tab + (1 if d.x < 0 else -1))


func _swipe_allowed_at(point: Vector2) -> bool:
	if _any_modal_open():
		return false
	if _pages_clip == null or not _pages_clip.get_global_rect().has_point(point):
		return false
	for blocker in _swipe_blockers:
		if blocker != null and blocker.is_visible_in_tree() and blocker.get_global_rect().has_point(point):
			return false
	return true


func _any_modal_open() -> bool:
	for panel: Control in [_hero_panel, _hero_detail_panel, _mode_panel, _settings_panel]:
		if panel != null and panel.visible:
			return true
	return _collection_panel != null and _collection_panel._detail_sheet != null \
			and _collection_panel._detail_sheet.visible


## Tasto indietro di Android: chiude la modale aperta, poi riporta alla
## scheda Battaglia, e solo da lì esce dal gioco.
func _enter_tree() -> void:
	get_tree().quit_on_go_back = false


func _exit_tree() -> void:
	get_tree().quit_on_go_back = true


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if _any_modal_open():
		for panel: Control in [_hero_panel, _hero_detail_panel, _mode_panel, _settings_panel]:
			panel.visible = false
		_collection_panel._detail_sheet.visible = false
	elif _current_tab != TAB_BATTLE:
		select_tab(TAB_BATTLE)
	else:
		get_tree().quit()


## Dentro uno ScrollContainer il figlio è dimensionato al proprio minimo, non
## riempie il contenitore: _grow_spacer con SIZE_EXPAND_FILL da solo non fa
## più nulla, quindi qui si misura a mano quanto avanza e lo si dà a lui, così
## eroe e pulsanti restano spinti in basso invece di ammucchiarsi sotto al
## titolo con un vuoto sotto — esattamente il buco lasciato da Esci. Se il
## contenuto non ci sta (schermo basso), lo spazio calcolato è 0 e resta lo
## scorrimento come rete di sicurezza.
func _apply_layout() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _content_column == null or _content_scroll == null or _grow_spacer == null:
		return
	var available := _content_scroll.size.y
	# Il minimo della colonna include già il vuoto assegnato la volta prima:
	# va tolto, o ogni ricalcolo (avvio, resize, layout delle pagine) ne
	# restituirebbe solo una parte e i pulsanti risalirebbero.
	var content_min := _content_column.get_combined_minimum_size().y - _grow_spacer.custom_minimum_size.y
	_grow_spacer.custom_minimum_size.y = maxf(0.0, available - content_min)


func _banner() -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 12)
	wrap.add_child(Style.title_plate())

	var subtitle := Label.new()
	subtitle.text = tr("MENU_SUBTITLE")
	subtitle.add_theme_font_size_override("font_size", 21)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", Style.TEXT_DIM)
	wrap.add_child(subtitle)

	return wrap


## Modello 3D vivo dell'eroe scelto, sopra alla riga di battaglia, col nome
## sopra: è la conferma visiva di chi si sta per portare in campo, e si può
## ruotare trascinandolo per guardarlo da ogni lato.
func _hero_display() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)

	_hero_name_label = Label.new()
	_hero_name_label.add_theme_font_size_override("font_size", 34)
	_hero_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hero_name_label.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(_hero_name_label)

	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	frame.custom_minimum_size = Vector2(0, HERO_VIEW_SIZE + 6)
	column.add_child(frame)

	var center := CenterContainer.new()
	frame.add_child(center)

	var viewport_container := SubViewportContainer.new()
	viewport_container.custom_minimum_size = Vector2(HERO_VIEW_SIZE, HERO_VIEW_SIZE)
	viewport_container.stretch = true
	viewport_container.mouse_filter = Control.MOUSE_FILTER_STOP
	viewport_container.gui_input.connect(_on_hero_viewport_input)
	center.add_child(viewport_container)
	_swipe_blockers.append(viewport_container)

	_build_hero_viewport(viewport_container)

	return column


## Stessa impostazione di luci/camera della scheda unità in collezione: qui
## però il viewport resta vivo (UPDATE_ALWAYS) perché il modello ruota mentre
## il giocatore lo trascina, non è una posa fissa da fotografare una volta.
func _build_hero_viewport(container: SubViewportContainer) -> void:
	_hero_viewport = SubViewport.new()
	_hero_viewport.size = Vector2i(HERO_VIEW_SIZE, HERO_VIEW_SIZE)
	_hero_viewport.transparent_bg = true
	_hero_viewport.own_world_3d = true
	_hero_viewport.msaa_3d = Viewport.MSAA_4X
	_hero_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_hero_viewport)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.58, 0.62, 0.72)
	environment.ambient_light_energy = 0.9

	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	_hero_viewport.add_child(world_environment)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, 34, 0)
	key.light_energy = 1.25
	key.light_color = Color(1.0, 0.96, 0.9)
	_hero_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-16, -145, 0)
	fill.light_energy = 0.5
	fill.light_color = Color(0.68, 0.76, 1.0)
	_hero_viewport.add_child(fill)

	_hero_camera = Camera3D.new()
	_hero_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_hero_camera.near = 0.05
	_hero_camera.far = 20.0
	_hero_viewport.add_child(_hero_camera)

	_hero_model_root = Node3D.new()
	_hero_viewport.add_child(_hero_model_root)


## Trascinare col dito/mouse sopra il modello lo ruota sull'asse verticale;
## non serve altro (zoom, inclinazione) per una vetrina di conferma come
## questa.
func _on_hero_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_hero_dragging = mb.pressed
			_hero_drag_last_x = mb.position.x
			if mb.pressed:
				_hero_auto_rotating = false
	elif event is InputEventMouseMotion and _hero_dragging:
		var mm := event as InputEventMouseMotion
		var delta_x := mm.position.x - _hero_drag_last_x
		_hero_drag_last_x = mm.position.x
		if _hero_model_root != null:
			_hero_model_root.rotate_y(deg_to_rad(delta_x) * 0.6)


## Etichetta vuota e nascosta finché _refresh_rank_label() non trova uno stato
## di login con un mmr da mostrare — costruita comunque qui, sotto l'eroe,
## perché il layout ha già lo spazio riservato quando arriva il dato.
func _rank_readout() -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Style.GOLD.darkened(0.1))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.visible = false
	return label


## Auth.stats["mmr"] arriva col login (bundle AUTH_OK) e viene tenuto
## aggiornato in partita da RemoteSession (RANK_UPDATE) — qui si legge soltanto,
## mai calcolato: il grado in sé lo assegna GameData.rank_for_mmr() dai nomi in
## data/balance.json. Da ospite (niente Auth, o non loggato) resta nascosta:
## un mmr non esiste finché non esiste un account.
func _refresh_rank_label() -> void:
	if _rank_label == null:
		return
	var auth := get_node_or_null("/root/Auth")
	if auth == null or not auth.is_logged_in() or not auth.stats.has("mmr"):
		_rank_label.visible = false
		return
	var mmr := int(auth.stats.get("mmr", 0))
	var rank := GameData.rank_for_mmr(mmr)
	_rank_label.text = "🏅 %s · %d mmr" % [rank.get("name", "—"), mmr]
	_rank_label.visible = true


func _refresh_hero_model() -> void:
	if _hero_name_label != null:
		var hdef := GameData.hero(_selected_hero)
		_hero_name_label.text = hdef.display_name if hdef != null else _selected_hero

	if _hero_viewport == null or not GameData.has_hero(_selected_hero):
		return
	for child in _hero_model_root.get_children():
		_hero_model_root.remove_child(child)
		child.queue_free()
	_hero_model_root.add_child(UnitModels.build_hero(_selected_hero))
	_hero_model_root.rotation.y = 0.0

	var height := UnitModels.height_of_hero(_selected_hero)
	var centre := Vector3(0, height * 0.58, 0)
	_hero_camera.size = height * HERO_ZOOM
	_hero_camera.position = centre + HERO_CAMERA_OFFSET
	_hero_camera.look_at(centre, Vector3.UP)


## BATTAGLIA affiancato dai due pulsanti che aprono le modali piccole: eroe a
## sinistra, modalità a destra. Il pulsante centrale resta il bersaglio
## principale, i due laterali sono solo scorciatoie verso le scelte.
func _battle_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	_hero_button = Button.new()
	_hero_button.custom_minimum_size = Vector2(64, Style.TOUCH_PRIMARY)
	_hero_button.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(_hero_button, Style.PLATE, Style.PLATE_DARK, 18, 6)
	_hero_button.pressed.connect(func() -> void: _hero_panel.visible = true)
	row.add_child(_hero_button)

	row.add_child(_play_button())

	_mode_button = Button.new()
	_mode_button.custom_minimum_size = Vector2(64, Style.TOUCH_PRIMARY)
	_mode_button.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(_mode_button, Style.PLATE, Style.PLATE_DARK, 18, 6)
	_mode_button.pressed.connect(func() -> void: _mode_panel.visible = true)
	row.add_child(_mode_button)

	return row


## L'unico pulsante che deve essere impossibile da mancare: più caldo di tutto
## il resto, e stretto tra le due scorciatoie eroe/modalità.
func _play_button() -> Button:
	var play := Button.new()
	play.text = tr("MENU_PLAY")
	play.custom_minimum_size = Vector2(0, Style.TOUCH_PRIMARY)
	play.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	play.add_theme_font_size_override("font_size", 30)
	play.add_theme_color_override("font_color", Style.INK)
	play.add_theme_color_override("font_hover_color", Style.INK)
	play.add_theme_color_override("font_pressed_color", Style.INK)
	Style.apply_plate(play, Style.GOLD, Style.GOLD_DEEP, 22, 9)
	play.pressed.connect(_on_play_pressed)
	return play


## Scaffolding condiviso da tutte le modali piccole: un fondale semitrasparente
## a tutto schermo (chiude al click fuori) e un pannello centrato sopra di
## esso, invece del pannello fullscreen opaco usato in precedenza.
##
## Il pannello è ancorato a una frazione centrata dello schermo (non a un
## centro fisso con dimensione fissa): così cresce con la finestra invece di
## restare piccolo su schermi grandi, e min_size fa solo da pavimento sui
## telefoni più stretti, dove Godot clampa comunque la size effettiva.
func _build_small_modal(min_size: Vector2) -> Panel:
	var backdrop := ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0, 0, 0, 0.55)
	backdrop.visible = false
	add_child(backdrop)

	var panel := Panel.new()
	panel.anchor_left = 0.08
	panel.anchor_right = 0.92
	panel.anchor_top = 0.08
	panel.anchor_bottom = 0.92
	panel.offset_left = 0
	panel.offset_right = 0
	panel.offset_top = 0
	panel.offset_bottom = 0
	panel.custom_minimum_size = min_size
	panel.add_theme_stylebox_override("panel", Style.plate(Style.STONE.darkened(0.3), Style.GOLD_DEEP, 20, 8))
	panel.visible = false
	add_child(panel)

	# Il backdrop segue la visibilità del pannello, e un click su di esso chiude
	# la modale come premere "Chiudi".
	panel.visibility_changed.connect(func() -> void: backdrop.visible = panel.visible)
	var close_on_backdrop := Button.new()
	close_on_backdrop.flat = true
	close_on_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	close_on_backdrop.pressed.connect(func() -> void: panel.visible = false)
	backdrop.add_child(close_on_backdrop)

	return panel


## Modale di selezione della modalità: due carte piccole, centrate sullo
## schermo invece che a piena pagina.
func _build_mode_panel() -> void:
	_mode_panel = _build_small_modal(Vector2(360, 320))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	_mode_panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.text = tr("MENU_CHOOSE_MODE")
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(title)

	column.add_child(_mode_option(MODE_CPU, "🖥️  " + tr("MENU_MODE_CPU"),
		tr("MENU_MODE_CPU_HINT")))
	column.add_child(_mode_option(MODE_PVP, "👥  " + tr("MENU_MODE_PVP"),
		tr("MENU_MODE_PVP_HINT")))

	column.add_child(_grow())

	var close := Button.new()
	close.text = tr("UI_CLOSE")
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 20)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 18, 6)
	close.pressed.connect(func() -> void: _mode_panel.visible = false)
	column.add_child(close)


func _mode_option(mode: String, label_text: String, hint_text: String) -> Control:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 4)

	var button := Button.new()
	button.text = label_text
	button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(func() -> void: _on_mode_pressed(mode))
	card.add_child(button)
	_mode_option_buttons[mode] = button

	var hint := Label.new()
	hint.text = hint_text
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Style.TEXT_DIM)
	card.add_child(hint)

	return card


## Modale di selezione dell'eroe: una carta per eroe disponibile. Toccare una
## carta non seleziona subito l'eroe, apre la scheda di dettaglio (ritratto e
## informazioni storiche); la selezione vera avviene da lì.
func _build_hero_panel() -> void:
	_hero_panel = _build_small_modal(Vector2(360, 380))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	_hero_panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.text = tr("MENU_CHOOSE_HERO")
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(title)

	# Scroll invece di affidarsi allo spazio della modale: con più eroi di
	# quanti ne stiano a schermo l'elenco non deve tagliare le ultime carte.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 12)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	for hdef in GameData.all_heroes():
		list.add_child(_hero_option(hdef))

	var close := Button.new()
	close.text = tr("UI_CLOSE")
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 20)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 18, 6)
	close.pressed.connect(func() -> void: _hero_panel.visible = false)
	column.add_child(close)


func _hero_option(hdef: HeroDef) -> Control:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 4)

	var button := Button.new()
	button.text = hdef.display_name
	button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(func() -> void: _open_hero_detail(hdef.id))
	card.add_child(button)
	_hero_option_buttons[hdef.id] = button

	var hint := Label.new()
	hint.text = hdef.ability_text
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Style.TEXT_DIM)
	card.add_child(hint)

	return card


## Scheda di dettaglio dell'eroe: ritratto, nome, civiltà e un breve testo
## storico, con la selezione vera e propria affidata al pulsante in fondo.
func _build_hero_detail_panel() -> void:
	_hero_detail_panel = _build_small_modal(Vector2(360, 440))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	_hero_detail_panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var detail_center := CenterContainer.new()
	column.add_child(detail_center)

	var detail_viewport_container := SubViewportContainer.new()
	detail_viewport_container.custom_minimum_size = Vector2(HERO_DETAIL_VIEW_SIZE, HERO_DETAIL_VIEW_SIZE)
	detail_viewport_container.stretch = true
	detail_viewport_container.mouse_filter = Control.MOUSE_FILTER_STOP
	detail_viewport_container.gui_input.connect(_on_hero_detail_viewport_input)
	detail_center.add_child(detail_viewport_container)

	_build_hero_detail_viewport(detail_viewport_container)

	_hero_detail_name = Label.new()
	_hero_detail_name.add_theme_font_size_override("font_size", 24)
	_hero_detail_name.add_theme_color_override("font_color", Style.GOLD)
	_hero_detail_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_hero_detail_name)

	_hero_detail_origin = Label.new()
	_hero_detail_origin.add_theme_font_size_override("font_size", 16)
	_hero_detail_origin.add_theme_color_override("font_color", Style.TEXT_DIM)
	_hero_detail_origin.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_hero_detail_origin)

	# Lo scroll copre sia la descrizione storica sia l'abilità: testi più
	# lunghi di quanti la modale ne contenga a vista non vengono tagliati.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)

	var text_column := VBoxContainer.new()
	text_column.add_theme_constant_override("separation", 8)
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(text_column)

	_hero_detail_lore = Label.new()
	_hero_detail_lore.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hero_detail_lore.add_theme_font_size_override("font_size", 16)
	text_column.add_child(_hero_detail_lore)

	_hero_detail_ability = Label.new()
	_hero_detail_ability.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hero_detail_ability.add_theme_font_size_override("font_size", 15)
	_hero_detail_ability.add_theme_color_override("font_color", Style.TEXT_DIM)
	text_column.add_child(_hero_detail_ability)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	column.add_child(buttons)

	var back := Button.new()
	back.text = tr("UI_BACK")
	back.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back.add_theme_font_size_override("font_size", 18)
	Style.apply_plate(back, Style.PLATE, Style.PLATE_DARK, 18, 6)
	back.pressed.connect(func() -> void:
		_hero_detail_panel.visible = false
		_hero_panel.visible = true)
	buttons.add_child(back)

	_hero_detail_select = Button.new()
	_hero_detail_select.text = tr("UI_SELECT")
	_hero_detail_select.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	_hero_detail_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hero_detail_select.add_theme_font_size_override("font_size", 18)
	_hero_detail_select.add_theme_color_override("font_color", Style.INK)
	Style.apply_plate(_hero_detail_select, Style.GOLD, Style.GOLD_DEEP, 18, 6)
	_hero_detail_select.pressed.connect(func() -> void: _on_hero_pressed(_hero_detail_id))
	buttons.add_child(_hero_detail_select)


## Stessa impostazione di luci/camera della vetrina dell'eroe in home: qui
## però non serve UPDATE_ALWAYS perché si aggiorna anche al solo trascinamento.
func _build_hero_detail_viewport(container: SubViewportContainer) -> void:
	_hero_detail_viewport = SubViewport.new()
	_hero_detail_viewport.size = Vector2i(HERO_DETAIL_VIEW_SIZE, HERO_DETAIL_VIEW_SIZE)
	_hero_detail_viewport.transparent_bg = true
	_hero_detail_viewport.own_world_3d = true
	_hero_detail_viewport.msaa_3d = Viewport.MSAA_4X
	_hero_detail_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_hero_detail_viewport)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.58, 0.62, 0.72)
	environment.ambient_light_energy = 0.9

	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	_hero_detail_viewport.add_child(world_environment)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, 34, 0)
	key.light_energy = 1.25
	key.light_color = Color(1.0, 0.96, 0.9)
	_hero_detail_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-16, -145, 0)
	fill.light_energy = 0.5
	fill.light_color = Color(0.68, 0.76, 1.0)
	_hero_detail_viewport.add_child(fill)

	_hero_detail_camera = Camera3D.new()
	_hero_detail_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_hero_detail_camera.near = 0.05
	_hero_detail_camera.far = 20.0
	_hero_detail_viewport.add_child(_hero_detail_camera)

	_hero_detail_model_root = Node3D.new()
	_hero_detail_viewport.add_child(_hero_detail_model_root)


func _on_hero_detail_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_hero_detail_dragging = mb.pressed
			_hero_detail_drag_last_x = mb.position.x
			if mb.pressed:
				_hero_detail_auto_rotating = false
	elif event is InputEventMouseMotion and _hero_detail_dragging:
		var mm := event as InputEventMouseMotion
		var delta_x := mm.position.x - _hero_detail_drag_last_x
		_hero_detail_drag_last_x = mm.position.x
		if _hero_detail_model_root != null:
			_hero_detail_model_root.rotate_y(deg_to_rad(delta_x) * 0.6)


func _show_hero_detail_model(hero_id: String) -> void:
	if _hero_detail_viewport == null or not GameData.has_hero(hero_id):
		return
	for child in _hero_detail_model_root.get_children():
		_hero_detail_model_root.remove_child(child)
		child.queue_free()
	_hero_detail_model_root.add_child(UnitModels.build_hero(hero_id))
	_hero_detail_model_root.rotation.y = 0.0
	_hero_detail_auto_rotating = true

	var height := UnitModels.height_of_hero(hero_id)
	var centre := Vector3(0, height * 0.58, 0)
	_hero_detail_camera.size = height * HERO_DETAIL_ZOOM
	_hero_detail_camera.position = centre + HERO_DETAIL_CAMERA_OFFSET
	_hero_detail_camera.look_at(centre, Vector3.UP)


func _open_hero_detail(hero_id: String) -> void:
	var hdef := GameData.hero(hero_id)
	_hero_detail_id = hero_id
	_hero_detail_name.text = hdef.display_name
	_hero_detail_origin.text = String(GameData.trait_def(hdef.origin).get("name", hdef.origin))
	_hero_detail_lore.text = hdef.lore
	_hero_detail_ability.text = hdef.ability_text
	_show_hero_detail_model(hero_id)
	_hero_panel.visible = false
	_hero_detail_panel.visible = true


## Spaziatore elastico: assorbe lui l'altezza in più dei telefoni allungati,
## così su 19.5:9 il menu si distribuisce invece di lasciare un buco in fondo.
func _grow() -> Control:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return spacer


# --------------------------------------------------------------------------
# Azioni
# --------------------------------------------------------------------------

func _on_play_pressed() -> void:
	if _match_mode == MODE_PVP:
		_start_pvp()
		return

	get_tree().change_scene_to_file(GAME_SCENE)


## Contro giocatori: serve un account. Se già loggati si va in lobby; se no —
## il caso dell'ospite, l'unico che arriva qui senza sessione, visto che la
## scena di login precede il menu — si spiega perché e dove rimediare, invece
## di mandarlo a login.tscn: da ospite quella scena rimbalza subito indietro
## (is_guest()) e il pulsante sembrerebbe rotto. Senza l'autoload Auth (edge
## headless) si ricade sul vecchio avviso "in arrivo".
func _start_pvp() -> void:
	if DevNet.enabled():
		# Sviluppo locale: niente login, master/worker headless su 127.0.0.1.
		get_tree().change_scene_to_file(LOBBY_SCENE)
		return
	var auth := get_node_or_null("/root/Auth")
	if auth == null:
		_show_pvp_unavailable(tr("MENU_PVP_COMING_SOON"))
		return
	if auth.is_logged_in():
		get_tree().change_scene_to_file(LOBBY_SCENE)
		return
	_show_pvp_unavailable(tr("MENU_PVP_NEEDS_ACCOUNT"))


func _show_pvp_unavailable(message: String) -> void:
	ModalDialog.notice(self, tr("MENU_MODE_PVP"), message)


func _on_collection_pressed() -> void:
	select_tab(TAB_COLLECTION)


func _on_store_pressed() -> void:
	select_tab(TAB_STORE)


func _on_guide_pressed() -> void:
	select_tab(TAB_GUIDE)


func _on_history_pressed() -> void:
	select_tab(TAB_HISTORY)
	_show_history_section(false)


func _on_leaderboard_pressed() -> void:
	select_tab(TAB_HISTORY)
	_show_history_section(true)


## La modalità salvata, o "contro il computer" se il profilo non ne ha ancora
## una (primo avvio) o ne ha una che questa versione non conosce.
func _restored_mode() -> String:
	var saved := String(_profile.match_mode)
	return saved if saved == MODE_CPU or saved == MODE_PVP else MODE_CPU


func _on_mode_pressed(mode: String) -> void:
	_match_mode = mode
	_profile.set_match_mode(mode)
	_update_mode_button()
	_mode_panel.visible = false


func _update_mode_button() -> void:
	if _match_mode == MODE_PVP:
		_mode_button.text = "👥"
		_mode_button.tooltip_text = tr("MENU_MODE_TOOLTIP") % tr("MENU_MODE_PVP")
	else:
		_mode_button.text = "🖥️"
		_mode_button.tooltip_text = tr("MENU_MODE_TOOLTIP") % tr("MENU_MODE_CPU")

	for mode in _mode_option_buttons:
		var button: Button = _mode_option_buttons[mode]
		var selected: bool = mode == _match_mode
		Style.apply_plate(button, Style.GOLD if selected else Style.PLATE, Style.GOLD_DEEP if selected else Style.PLATE_DARK, 18, 6)
		button.add_theme_color_override("font_color", Style.INK if selected else Style.TEXT_DIM)


func _on_hero_pressed(hero_id: String) -> void:
	_selected_hero = hero_id
	_profile.set_favourite_hero(hero_id)
	_update_hero_button()
	_refresh_hero_model()
	_hero_panel.visible = false
	if _hero_detail_panel != null:
		_hero_detail_panel.visible = false


func _update_hero_button() -> void:
	var hdef := GameData.hero(_selected_hero)
	_hero_button.text = "🛡️"
	_hero_button.tooltip_text = tr("MENU_HERO_TOOLTIP") % (hdef.display_name if hdef != null else _selected_hero)

	for hero_id in _hero_option_buttons:
		var button: Button = _hero_option_buttons[hero_id]
		var selected: bool = hero_id == _selected_hero
		Style.apply_plate(button, Style.GOLD if selected else Style.PLATE, Style.GOLD_DEEP if selected else Style.PLATE_DARK, 18, 6)
		button.add_theme_color_override("font_color", Style.INK if selected else Style.TEXT_DIM)
