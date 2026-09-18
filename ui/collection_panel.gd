class_name CollectionPanel
extends Panel

## Enciclopedia delle unità: tutto ciò che si può incontrare in partita.
##
## Legge da GameData, quindi non va aggiornata quando si aggiunge una civiltà:
## le nuove unità compaiono da sole. Mostra sempre l'intero roster, anche le
## civiltà non acquistate, perché in modalità condivisa si incontrano lo stesso
## nelle squadre avversarie — nasconderle renderebbe il gioco meno leggibile,
## non più desiderabile.
##
## In portrait la scheda non sta a fianco della griglia: si apre sopra, al
## tocco. Una colonna di dettaglio larga 360 px accanto a una griglia toglierebbe
## metà schermo a entrambe.

signal closed

## Vero quando il pannello è una pagina della home a schede (ui/menu.gd):
## niente pulsante Chiudi — si esce cambiando scheda — e resta visibile dentro
## la sua pagina. Va impostato prima di add_child, che fa partire _ready().
var embedded := false

## Tre colonne: su 720 px di larghezza ogni casella resta sopra i 200 px, cioè
## abbastanza da far leggere la figura. Con sei diventavano francobolli.
const GRID_COLUMNS := 3
const SLOT_SIZE := Vector2(206, 184)

var _grid: GridContainer
## Filtri a scorrimento orizzontale: la home a schede non ci fa partire lo
## swipe di pagina sopra.
var filter_scroll: ScrollContainer
var _detail: RichTextLabel
var _detail_sheet: Panel
var _detail_viewport: SubViewport
var _detail_camera: Camera3D
var _detail_model_root: Node3D
var _detail_dragging := false
var _detail_drag_last_x := 0.0
var _filter_origin: String = ""
var _filter_buttons: Dictionary = {}
## Elenco (filtrato) mostrato in griglia, per scorrere avanti/indietro dalla
## scheda di dettaglio senza doverla richiudere.
var _shown_ids: Array[String] = []
var _detail_index := -1
var _detail_viewport_container: Control
## Contenuto scorrevole (modello + testo) dentro la scheda: quello che scivola
## durante l'animazione di cambio unità, frecce e pulsante Chiudi restano fermi.
var _detail_content: Control
var _detail_sliding := false
var _swipe_tracking := false
var _swipe_start := Vector2.ZERO
## Stessa soglia dello swipe fra schede della home (ui/menu.gd).
const SWIPE_MIN_PX := 90.0
const SWIPE_AXIS_RATIO := 1.6
## Stessa durata/curva dello scorrimento fra schede della home
## (ui/menu.gd PAGE_SLIDE_SECONDS), qui applicata a metà corsa perché il
## contenuto della scheda esce e rientra in due tratti separati.
const DETAIL_SLIDE_SECONDS := 0.15
## Vero finché il giocatore non tocca il modello: si spegne al primo drag e
## resta spento per quell'unità (si riaccende mostrandone un'altra).
var _auto_rotating := true

## Inquadratura della scheda: più ravvicinata di quella delle caselline, dato
## che qui il modello è il punto della pagina e non un'icona fra le tante.
## Il modello è il motivo per cui si apre la scheda, quindi prende la parte
## del leone: più delle caselline della griglia, la scritta serve solo a
## confermare cosa si sta guardando.
const DETAIL_VIEW_SIZE := 340
const DETAIL_CAMERA_OFFSET := Vector3(1.15, 1.35, 2.05)
## Più largo di quanto l'altezza da sola richieda: la camera inquadra in base
## alla sola altezza del modello, ma ruotando un'unità lunga (i bracci del
## balestrone, una lancia tenuta di traverso) può sporgere più larga che alta
## e uscire dall'inquadratura. Il margine in più tiene la sagoma dentro anche
## quando gira.
const DETAIL_ZOOM := 1.9
## Un giro completo ogni 24 secondi: abbastanza lento da leggersi come "questo
## si guarda da tutti i lati", non come qualcosa che gira per conto suo.
const AUTO_ROTATE_SPEED := TAU / 24.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	visible = embedded
	_build()


func _process(delta: float) -> void:
	if _auto_rotating and _detail_sheet != null and _detail_sheet.visible and _detail_model_root != null:
		_detail_model_root.rotate_y(AUTO_ROTATE_SPEED * delta)


## Scorrimento orizzontale sulla scheda di dettaglio: passa all'unità
## successiva/precedente della griglia (filtrata) corrente senza chiudere la
## scheda. Ignora i tocchi che partono sul modello 3D, che lì servono a
## ruotarlo — stessa distinzione di ui/menu.gd fra swipe di pagina e i suoi
## _swipe_blockers.
func _input(event: InputEvent) -> void:
	if _detail_sheet == null or not _detail_sheet.visible:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		_swipe_tracking = not _point_in_detail_viewport(mb.position)
		_swipe_start = mb.position
		return
	if not _swipe_tracking:
		return
	_swipe_tracking = false
	var d := mb.position - _swipe_start
	if absf(d.x) >= SWIPE_MIN_PX and absf(d.x) >= absf(d.y) * SWIPE_AXIS_RATIO:
		_step_detail(1 if d.x < 0 else -1)


func _point_in_detail_viewport(point: Vector2) -> bool:
	return _detail_viewport_container != null and _detail_viewport_container.get_global_rect().has_point(point)


## Gira in tondo (wrapi) invece di fermarsi ai bordi: la griglia è pensata per
## essere sfogliata di seguito, non per farsi cercare l'ultima unità apposta.
func _step_detail(direction: int) -> void:
	if _detail_sliding or _detail_content == null:
		return
	if _shown_ids.size() <= 1 or _detail_index < 0:
		return
	_detail_index = wrapi(_detail_index + direction, 0, _shown_ids.size())
	_slide_detail_to(_shown_ids[_detail_index], direction)


## Stessa animazione di cambio scheda della home (ui/menu.gd select_tab): il
## contenuto uscente scivola da un lato, quello nuovo entra dall'altro. Qui è
## in due tempi anziché una sola fila che scorre, perché la scheda ha un solo
## contenuto vivo (il viewport 3D) e non tante pagine già pronte affiancate.
func _slide_detail_to(unit_id: String, direction: int) -> void:
	_detail_sliding = true
	var width := maxf(_detail_content.size.x, 1.0)

	var out_tween := create_tween()
	out_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	out_tween.tween_property(_detail_content, "position:x", -direction * width, DETAIL_SLIDE_SECONDS)
	await out_tween.finished

	_show_detail(unit_id)
	_detail_content.position.x = direction * width

	var in_tween := create_tween()
	in_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	in_tween.tween_property(_detail_content, "position:x", 0.0, DETAIL_SLIDE_SECONDS)
	await in_tween.finished

	_detail_sliding = false


func open() -> void:
	visible = true
	var ids: Array = []
	for def in GameData.all_units():
		ids.append(def.id)
	get_node("/root/Portraits").preload_units(ids)
	_refresh()


func _build() -> void:
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", Style.safe_top_margin())
	margin.add_theme_constant_override("margin_bottom", 8 if embedded else 18)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.text = tr("COLLECTION_TITLE")
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(title)

	# I filtri scorrono in orizzontale: con quattro civiltà ci stanno, con otto
	# no, e una riga che va a capo da sola sposterebbe la griglia ogni volta.
	filter_scroll = ScrollContainer.new()
	filter_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	filter_scroll.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	column.add_child(filter_scroll)

	var filters := HBoxContainer.new()
	filters.add_theme_constant_override("separation", 8)
	filter_scroll.add_child(filters)

	_filter_buttons[""] = _filter_button(filters, tr("COLLECTION_ALL"), Style.TEXT_DIM, "")
	for origin_id in GameData.origin_ids():
		var id := String(origin_id)
		_filter_buttons[id] = _filter_button(
			filters, GameData.trait_name(id), Style.origin_color(id), id)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_grid)

	if not embedded:
		var close := Button.new()
		close.text = tr("UI_CLOSE")
		close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
		close.add_theme_font_size_override("font_size", 26)
		Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 18, 6)
		close.pressed.connect(func() -> void:
			visible = false
			closed.emit())
		column.add_child(close)

	_build_detail_sheet()


func _filter_button(row: HBoxContainer, text: String, tint: Color, origin_id: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	button.add_theme_font_size_override("font_size", 22)
	button.add_theme_color_override("font_color", tint)
	button.pressed.connect(func() -> void:
		_filter_origin = origin_id
		_refresh())
	row.add_child(button)
	return button


## La scheda dell'unità, sopra la griglia. Vive sempre nell'albero perché il
## testo dev'essere leggibile anche a pannello chiuso: i test la interrogano
## senza aprirla, ed è così che si accorgono se smette di essere compilata.
func _build_detail_sheet() -> void:
	_detail_sheet = Panel.new()
	_detail_sheet.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail_sheet.add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.GOLD_DEEP, 2, 0))
	_detail_sheet.visible = false
	add_child(_detail_sheet)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	_detail_sheet.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	# Il contenuto scorrevole va ritagliato: senza clip_contents, farlo
	# scivolare fuori durante l'animazione lo farebbe uscire dal riquadro
	# invece di sparire dietro i bordi della scheda.
	var clip := Control.new()
	clip.clip_contents = true
	clip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(clip)

	_detail_content = VBoxContainer.new()
	_detail_content.add_theme_constant_override("separation", 12)
	_detail_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip.add_child(_detail_content)

	# Il modello 3D in cima, centrato: è la prima cosa che si vuole vedere
	# aprendo la scheda di un'unità, prima ancora delle statistiche.
	var viewport_center := CenterContainer.new()
	_detail_content.add_child(viewport_center)

	var viewport_container := SubViewportContainer.new()
	viewport_container.custom_minimum_size = Vector2(DETAIL_VIEW_SIZE, DETAIL_VIEW_SIZE)
	viewport_container.stretch = true
	viewport_container.mouse_filter = Control.MOUSE_FILTER_STOP
	viewport_container.gui_input.connect(_on_detail_viewport_input)
	viewport_center.add_child(viewport_container)
	_detail_viewport_container = viewport_container

	_build_detail_viewport(viewport_container)

	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.add_theme_font_size_override("normal_font_size", 20)
	_detail.add_theme_font_size_override("bold_font_size", 20)
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_content.add_child(_detail)

	# Frecce ai lati del pulsante Chiudi, non per tutta l'altezza della scheda:
	# è una barra di navigazione, non una zona di tocco che copre il modello.
	var bottom_row := HBoxContainer.new()
	bottom_row.add_theme_constant_override("separation", 6)
	column.add_child(bottom_row)

	bottom_row.add_child(_nav_arrow_button("<", -1))

	var close := Button.new()
	close.text = tr("UI_CLOSE")
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(close, Style.PLATE, Style.PLATE_DARK, 18, 6)
	close.pressed.connect(func() -> void: _detail_sheet.visible = false)
	bottom_row.add_child(close)

	bottom_row.add_child(_nav_arrow_button(">", 1))


## Freccia laterale che sposta la scheda all'unità precedente/successiva.
## direction è -1 (sinistra, unità precedente) o 1 (destra, unità successiva).
func _nav_arrow_button(label: String, direction: int) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(56, Style.TOUCH_MIN)
	button.add_theme_font_size_override("font_size", 28)
	Style.apply_plate(button, Style.PLATE, Style.PLATE_DARK, 14, 4)
	button.pressed.connect(_step_detail.bind(direction))
	return button


## Una postazione di rendering viva, non la texture statica di Portraits:
## qui l'unità è sola sulla pagina, quindi vale la spesa di un viewport 3D
## dedicato invece di condividere quelli del magazzino di ritratti.
func _build_detail_viewport(container: SubViewportContainer) -> void:
	_detail_viewport = SubViewport.new()
	_detail_viewport.size = Vector2i(DETAIL_VIEW_SIZE, DETAIL_VIEW_SIZE)
	_detail_viewport.transparent_bg = true
	_detail_viewport.own_world_3d = true
	_detail_viewport.msaa_3d = Viewport.MSAA_4X
	# Vivo come la vetrina dell'eroe in home: il modello ruota mentre lo si
	# trascina, non è una posa fissa da fotografare una volta.
	_detail_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_detail_viewport)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.58, 0.62, 0.72)
	environment.ambient_light_energy = 0.9

	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	_detail_viewport.add_child(world_environment)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, 34, 0)
	key.light_energy = 1.25
	key.light_color = Color(1.0, 0.96, 0.9)
	_detail_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-16, -145, 0)
	fill.light_energy = 0.5
	fill.light_color = Color(0.68, 0.76, 1.0)
	_detail_viewport.add_child(fill)

	_detail_camera = Camera3D.new()
	_detail_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_detail_camera.near = 0.05
	_detail_camera.far = 20.0
	_detail_viewport.add_child(_detail_camera)

	_detail_model_root = Node3D.new()
	_detail_viewport.add_child(_detail_model_root)


## Trascinare col dito/mouse sopra il modello lo ruota sull'asse verticale,
## come la vetrina dell'eroe in home.
func _on_detail_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_detail_dragging = mb.pressed
			_detail_drag_last_x = mb.position.x
			if mb.pressed:
				_auto_rotating = false
	elif event is InputEventMouseMotion and _detail_dragging:
		var mm := event as InputEventMouseMotion
		var delta_x := mm.position.x - _detail_drag_last_x
		_detail_drag_last_x = mm.position.x
		if _detail_model_root != null:
			_detail_model_root.rotate_y(deg_to_rad(delta_x) * 0.6)


func _show_model(def: UnitDef) -> void:
	if _detail_viewport == null:
		return
	for child in _detail_model_root.get_children():
		_detail_model_root.remove_child(child)
		child.queue_free()
	_detail_model_root.add_child(UnitModels.build(def.id, def.origin))
	_detail_model_root.rotation.y = 0.0
	_auto_rotating = true

	var height := UnitModels.height_of(def.id)
	var centre := Vector3(0, height * 0.58, 0)
	_detail_camera.size = height * DETAIL_ZOOM
	_detail_camera.position = centre + DETAIL_CAMERA_OFFSET
	_detail_camera.look_at(centre, Vector3.UP)


func _refresh() -> void:
	# Qui la ricostruzione è accettabile: il pannello non è aperto mentre lo si
	# aggiorna da un gestore di uno dei suoi stessi pulsanti di unità.
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()

	for id in _filter_buttons:
		var button: Button = _filter_buttons[id]
		var active: bool = _filter_origin == id
		Style.apply_plate(button, Style.PLATE, Style.GOLD if active else Style.PLATE_DARK, 16, 5)

	var shown: Array[UnitDef] = []
	for def in GameData.all_units():
		if _filter_origin.is_empty() or def.origin == _filter_origin:
			shown.append(def)

	# Ogni voce: la figura nella casella, nome e costo scritti sotto. Qui il
	# nome serve — è un'enciclopedia, non una scelta rapida — e tenerlo fuori
	# dalla casella lascia tutto lo spazio al modello.
	for def in shown:
		var entry := VBoxContainer.new()
		entry.add_theme_constant_override("separation", 2)

		var slot := UnitSlot.new()
		slot.custom_minimum_size = SLOT_SIZE
		slot.show_unit(def, 0, UnitSlot.Badge.NONE, Style.PANEL, Style.rarity_color(def.cost), 2)
		slot.pressed.connect(_open_detail.bind(def.id))
		entry.add_child(slot)

		var name := Label.new()
		name.text = def.display_name
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name.custom_minimum_size = Vector2(SLOT_SIZE.x, 0)
		name.add_theme_font_size_override("font_size", 18)
		name.add_theme_color_override("font_color", Style.origin_color(def.origin))
		entry.add_child(name)

		var cost := Label.new()
		cost.text = tr("UNIT_COST_GOLD") % def.cost
		cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost.add_theme_font_size_override("font_size", 18)
		cost.add_theme_color_override("font_color", Style.rarity_color(def.cost))
		entry.add_child(cost)

		# Le sinergie sotto la casella: in griglia si confrontano molte unità
		# di seguito, e sapere a quali tratti appartiene ciascuna evita di
		# doverle aprire una per una solo per ricordarselo.
		var synergies := Label.new()
		var trait_names: Array[String] = []
		for trait_id in def.traits():
			trait_names.append(GameData.trait_name(trait_id))
		synergies.text = ", ".join(trait_names)
		synergies.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		synergies.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		synergies.custom_minimum_size = Vector2(SLOT_SIZE.x, 0)
		synergies.add_theme_font_size_override("font_size", 15)
		synergies.add_theme_color_override("font_color", Style.TEXT_DIM)
		entry.add_child(synergies)

		_grid.add_child(entry)

	_shown_ids.clear()
	for def in shown:
		_shown_ids.append(def.id)

	if not shown.is_empty():
		_detail_index = 0
		_show_detail(shown[0].id)


## Tocco su una casella: compila la scheda e la porta in primo piano. Il
## riempimento resta separato dall'apertura perché al refresh la scheda va
## aggiornata ma non mostrata — altrimenti aprire la collezione ti sbatterebbe
## dritto sulla prima unità invece che sulla griglia.
func _open_detail(unit_id: String) -> void:
	_detail_index = _shown_ids.find(unit_id)
	_show_detail(unit_id)
	_detail_sheet.visible = true


func _show_detail(unit_id: String) -> void:
	var def := GameData.unit(unit_id)
	if def == null:
		return

	_show_model(def)

	var traits: Array[String] = []
	for trait_id in def.traits():
		traits.append(GameData.trait_name(trait_id))

	var lines: Array[String] = []
	lines.append("[b][font_size=30]%s[/font_size][/b]" % def.display_name)
	lines.append("[color=#9aa]%s[/color]" % (tr("UNIT_TRAITS_COST") % [", ".join(traits), def.cost]))
	lines.append("")

	# Le statistiche a tutte e tre le stelle: è l'informazione che serve
	# davvero per decidere se vale la pena inseguire una copia.
	lines.append("[b]%s[/b]" % tr("COLLECTION_STATS"))
	for star in [1, 2, 3]:
		lines.append("  %s  " % "★".repeat(star) + tr("COLLECTION_STAT_HP_DAMAGE") % [
			int(def.stat_at_star("hp", star)),
			int(def.stat_at_star("attack_damage", star)),
		])
	var stats := def.base_stats
	lines.append("  " + tr("COLLECTION_STAT_RANGE_SPEED") % [
		int(stats.get("range", 1)), float(stats.get("attack_speed", 0.0)),
	])
	lines.append("  " + tr("COLLECTION_STAT_ARMOR_MR") % [
		int(stats.get("armor", 0)), int(stats.get("magic_resist", 0)),
	])
	lines.append("  " + tr("COLLECTION_STAT_MANA") % [int(stats.get("mana_start", 0)), int(stats.get("mana_max", 0))])
	lines.append("")

	lines.append("[b]%s[/b]" % def.ability.get("name", "—"))
	lines.append(String(def.ability.get("description", "")))
	lines.append("")

	for trait_id in def.traits():
		var trait_def := GameData.trait_def(trait_id)
		lines.append("[b]%s[/b] — %s" % [trait_def.get("name", trait_id), trait_def.get("description", "")])
		for tier in trait_def.get("tiers", []):
			lines.append("  [color=#9aa]%d:[/color] %s" % [int(tier["count"]), String(tier.get("text", ""))])
		lines.append("")

	# Non tutte le unità hanno ancora una scheda storica: si aggiunge solo in
	# fondo, dopo le informazioni di gioco, e solo se presente.
	if not def.lore.is_empty():
		lines.append("[b]%s[/b]" % tr("COLLECTION_LORE"))
		lines.append("[color=#ccc]%s[/color]" % def.lore)
		lines.append("")

	_detail.text = "\n".join(lines)
