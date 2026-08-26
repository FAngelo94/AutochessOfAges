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

## Tre colonne: su 720 px di larghezza ogni casella resta sopra i 200 px, cioè
## abbastanza da far leggere la figura. Con sei diventavano francobolli.
const GRID_COLUMNS := 3
const SLOT_SIZE := Vector2(206, 184)

var _grid: GridContainer
var _detail: RichTextLabel
var _detail_sheet: Panel
var _detail_viewport: SubViewport
var _detail_camera: Camera3D
var _detail_model_root: Node3D
var _filter_origin: String = ""
var _filter_buttons: Dictionary = {}

## Inquadratura della scheda: più ravvicinata di quella delle caselline, dato
## che qui il modello è il punto della pagina e non un'icona fra le tante.
const DETAIL_VIEW_SIZE := 260
const DETAIL_CAMERA_OFFSET := Vector3(1.15, 1.35, 2.05)
const DETAIL_ZOOM := 1.6


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	visible = false
	_build()


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
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.text = "COLLEZIONE"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(title)

	# I filtri scorrono in orizzontale: con quattro civiltà ci stanno, con otto
	# no, e una riga che va a capo da sola sposterebbe la griglia ogni volta.
	var filter_scroll := ScrollContainer.new()
	filter_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	filter_scroll.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	column.add_child(filter_scroll)

	var filters := HBoxContainer.new()
	filters.add_theme_constant_override("separation", 8)
	filter_scroll.add_child(filters)

	_filter_buttons[""] = _filter_button(filters, "Tutte", Style.TEXT_DIM, "")
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

	var close := Button.new()
	close.text = "Chiudi"
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

	# Il modello 3D in cima, centrato: è la prima cosa che si vuole vedere
	# aprendo la scheda di un'unità, prima ancora delle statistiche.
	var viewport_center := CenterContainer.new()
	column.add_child(viewport_center)

	var viewport_container := SubViewportContainer.new()
	viewport_container.custom_minimum_size = Vector2(DETAIL_VIEW_SIZE, DETAIL_VIEW_SIZE)
	viewport_container.stretch = true
	viewport_center.add_child(viewport_container)

	_build_detail_viewport(viewport_container)

	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.add_theme_font_size_override("normal_font_size", 20)
	_detail.add_theme_font_size_override("bold_font_size", 20)
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_detail)

	var back := Button.new()
	back.text = "Indietro"
	back.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	back.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(back, Style.PLATE, Style.PLATE_DARK, 18, 6)
	back.pressed.connect(func() -> void: _detail_sheet.visible = false)
	column.add_child(back)


## Una postazione di rendering viva, non la texture statica di Portraits:
## qui l'unità è sola sulla pagina, quindi vale la spesa di un viewport 3D
## dedicato invece di condividere quelli del magazzino di ritratti.
func _build_detail_viewport(container: SubViewportContainer) -> void:
	_detail_viewport = SubViewport.new()
	_detail_viewport.size = Vector2i(DETAIL_VIEW_SIZE, DETAIL_VIEW_SIZE)
	_detail_viewport.transparent_bg = true
	_detail_viewport.own_world_3d = true
	_detail_viewport.msaa_3d = Viewport.MSAA_4X
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


func _show_model(def: UnitDef) -> void:
	if _detail_viewport == null:
		return
	for child in _detail_model_root.get_children():
		_detail_model_root.remove_child(child)
		child.queue_free()
	_detail_model_root.add_child(UnitModels.build(def.id, def.origin))

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
		cost.text = "%d oro" % def.cost
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

	if not shown.is_empty():
		_show_detail(shown[0].id)


## Tocco su una casella: compila la scheda e la porta in primo piano. Il
## riempimento resta separato dall'apertura perché al refresh la scheda va
## aggiornata ma non mostrata — altrimenti aprire la collezione ti sbatterebbe
## dritto sulla prima unità invece che sulla griglia.
func _open_detail(unit_id: String) -> void:
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
	lines.append("[color=#9aa]%s — %d oro[/color]" % [", ".join(traits), def.cost])
	lines.append("")

	# Le statistiche a tutte e tre le stelle: è l'informazione che serve
	# davvero per decidere se vale la pena inseguire una copia.
	lines.append("[b]Statistiche[/b]")
	for star in [1, 2, 3]:
		lines.append("  %s  salute %d, danno %d" % [
			"★".repeat(star),
			int(def.stat_at_star("hp", star)),
			int(def.stat_at_star("attack_damage", star)),
		])
	var stats := def.base_stats
	lines.append("  gittata %d, velocità d'attacco %.2f" % [
		int(stats.get("range", 1)), float(stats.get("attack_speed", 0.0)),
	])
	lines.append("  armatura %d, resistenza magica %d" % [
		int(stats.get("armor", 0)), int(stats.get("magic_resist", 0)),
	])
	lines.append("  mana %d/%d" % [int(stats.get("mana_start", 0)), int(stats.get("mana_max", 0))])
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
		lines.append("[b]Storia[/b]")
		lines.append("[color=#ccc]%s[/color]" % def.lore)
		lines.append("")

	_detail.text = "\n".join(lines)
