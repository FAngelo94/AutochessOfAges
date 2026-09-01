extends Control

## Schermata iniziale. È la scena principale del progetto: da qui si entra in
## partita, e la partita può tornare qui.
##
## Tenerla separata da ui/main.tscn — invece di sovrapporre l'ennesimo pannello
## — significa che iniziare una partita ricrea sempre uno stato pulito: nessun
## residuo del round precedente può sopravvivere a un cambio di scena.
##
## Il layout è pensato per il portrait 720×1280: una colonna sola, che riempie
## la larghezza invece di stare in una colonna centrata, e nessun bersaglio
## tattile sotto Style.TOUCH_MIN.

const GAME_SCENE := "res://ui/main.tscn"
const LOBBY_SCENE := "res://ui/lobby.tscn"

const MODE_CPU := "cpu"
const MODE_PVP := "pvp"

## Etichetta della modalità, centralizzata perché compare sia sopra al
## pulsante di scelta sia come titolo della modale.
const MODE_LABEL := "MODALITÀ"
const HERO_LABEL := "EROE"

## Geometria della facciata disegnata dietro al menu. Sono costanti e non
## frazioni dello schermo perché il viewport è a larghezza fissa (720, stretch
## "keep_width"): solo l'altezza cambia da telefono a telefono, e di quella si
## occupano lo spaziatore elastico e le colonne, che scendono fino in fondo.
const COLUMN_W := 58.0
## Coronamento merlato: la fascia di cielo in cima che i merli interrompono.
const FACADE_TOP := 26.0
## Linea d'imposta dell'arco: sopra c'è la muratura, sotto comincia il vano
## d'ingresso in cui vive tutto il menu.
const SPRING_Y := 196.0
const FLOOR_H := 46.0

## Vetrina 3D dell'eroe in cima alla schermata: stesse proporzioni della
## scheda unità in collezione, ma qui il modello è vivo e ruotabile a
## trascinamento invece che una posa fissa.
const HERO_VIEW_SIZE := 240
const HERO_CAMERA_OFFSET := Vector3(0, 1.35, 2.35)
const HERO_ZOOM := 1.7

## Gli autoload si prendono dall'albero e non per nome globale: gli script
## compilati da riga di comando (test headless) non li vedrebbero.
var _store: Node
var _profile: Node
var _store_panel: StorePanel
var _collection_panel: CollectionPanel
var _guide_panel: GuidePanel
var _guide_button: Button
var _settings_panel: SettingsPanel
var _mode_panel: Panel
var _mode_button: Button
var _mode_option_buttons: Dictionary = {}
var _match_mode: String = MODE_CPU

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

var _hero_detail_panel: Panel
var _hero_detail_id: String = ""
var _hero_detail_portrait: TextureRect
var _hero_detail_name: Label
var _hero_detail_origin: Label
var _hero_detail_lore: Label
var _hero_detail_ability: Label
var _hero_detail_select: Button


func _ready() -> void:
	GameData.ensure_loaded()
	_store = get_node("/root/Store")
	_profile = get_node("/root/Profile")
	_selected_hero = _profile.effective_hero()
	_match_mode = _restored_mode()
	_build()

	# I ritratti 3D si generano un fotogramma per unità: farlo qui, mentre il
	# giocatore guarda il menu, fa sì che collezione e partita li trovino già
	# pronti invece di vederli comparire a uno a uno.
	var ids: Array = []
	for def in GameData.all_units():
		ids.append(def.id)
	var portraits := get_node("/root/Portraits")
	portraits.preload_units(ids)
	portraits.preload_heroes(GameData.hero_ids())
	portraits.portrait_ready.connect(_on_portrait_ready)
	_refresh_hero_model()


# --------------------------------------------------------------------------
# Costruzione
# --------------------------------------------------------------------------

func _build() -> void:
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))
	add_child(_castle_backdrop())

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Il contenuto comincia dove finisce la pietra: colonne e arco sono
	# architettura, e nulla ci deve salire sopra, altrimenti tornano a essere
	# decorazione dietro al testo.
	margin.add_theme_constant_override("margin_left", int(COLUMN_W) + 14)
	margin.add_theme_constant_override("margin_right", int(COLUMN_W) + 14)
	margin.add_theme_constant_override("margin_top", int(SPRING_Y) + 16)
	margin.add_theme_constant_override("margin_bottom", int(FLOOR_H) + 6)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)

	# Il titolo è ancorato in alto, appena sotto l'arco: se galleggiasse su uno
	# spaziatore elastico si staccherebbe dalla cornice su ogni schermo diverso.
	column.add_child(_banner())
	column.add_child(_grow())
	column.add_child(_hero_display())
	column.add_child(_spacer(6))
	column.add_child(_battle_row())
	column.add_child(_nav_bar())

	# Su Android e Web l'uscita non ha senso: là si esce dal sistema operativo
	# o chiudendo la scheda, e un pulsante che non fa nulla è peggio che assente.
	if OS.get_name() not in ["Android", "Web", "iOS"]:
		var quit := Button.new()
		quit.text = "Esci"
		quit.flat = true
		quit.custom_minimum_size = Vector2(0, 56)
		quit.add_theme_font_size_override("font_size", 20)
		quit.add_theme_color_override("font_color", Style.TEXT_DIM)
		quit.pressed.connect(func() -> void: get_tree().quit())
		column.add_child(quit)

	_store_panel = StorePanel.new()
	add_child(_store_panel)

	_collection_panel = CollectionPanel.new()
	add_child(_collection_panel)

	_guide_panel = GuidePanel.new()
	add_child(_guide_panel)

	_settings_panel = SettingsPanel.new()
	add_child(_settings_panel)

	_build_mode_panel()
	_update_mode_button()
	_build_hero_panel()
	_build_hero_detail_panel()
	_update_hero_button()


## Ingresso di un castello disegnato a runtime dietro al menu: due colonne di
## pietra a tutta altezza sui bordi e un arco a incorniciare il titolo. Stesso
## principio del resto dell'interfaccia, zero asset su disco.
##
## Non è un fondale qualsiasi: il layout gli lascia apposta i due margini
## laterali e la fascia alta, così la cornice sta sempre dove c'è spazio vuoto
## e non finisce mai sotto ai pannelli, dove sparirebbe del tutto.
func _castle_backdrop() -> Control:
	var canvas := Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.draw.connect(_draw_castle.bind(canvas))
	canvas.resized.connect(canvas.queue_redraw)
	return canvas


func _draw_castle(canvas: Control) -> void:
	var s := canvas.size
	if s.x <= 0.0 or s.y <= 0.0:
		return

	# Vano d'ingresso: mezza ellisse fra le due colonne. Ellisse e non
	# semicerchio perché il raggio di un arco a tutto sesto largo 600 px
	# arriverebbe ben oltre il bordo alto dello schermo.
	var cx := s.x * 0.5
	var half := cx - COLUMN_W
	var rise := (SPRING_Y - FACADE_TOP) * 0.85

	_draw_merlons(canvas, s)
	_draw_facade(canvas, s, cx, half, rise)
	_draw_columns(canvas, s)
	_draw_arch(canvas, cx, half, rise)
	_draw_floor(canvas, s)
	_draw_torches(canvas, s)


## Altezza della muratura a una data ascissa: sopra l'arco la facciata si
## assottiglia fino alla chiave di volta, ai lati scende fino all'imposta.
func _facade_bottom(x: float, cx: float, half: float, rise: float) -> float:
	var d: float = absf(x - cx)
	if d >= half:
		return SPRING_Y
	return SPRING_Y - rise * sqrt(1.0 - (d / half) * (d / half))


## Semiampiezza del vano a una data quota: serve per interrompere i corsi di
## pietra sul bordo dell'arco invece di farli attraversare l'apertura.
func _opening_half(y: float, half: float, rise: float) -> float:
	var d := SPRING_Y - y
	if d <= 0.0:
		return half
	if d >= rise:
		return 0.0
	return half * sqrt(1.0 - (d / rise) * (d / rise))


## Merlature contro il cielo: sono la prima cosa che si vede in cima allo
## schermo, ed è quello che fa leggere la pietra come un castello e non un muro.
func _draw_merlons(canvas: Control, s: Vector2) -> void:
	var x := 0.0
	while x < s.x:
		canvas.draw_rect(Rect2(Vector2(x, 0.0), Vector2(30.0, FACADE_TOP + 2.0)), Style.STONE)
		canvas.draw_rect(Rect2(Vector2(x, 0.0), Vector2(30.0, 4.0)), Style.STONE_LIT)
		x += 52.0


## La muratura si riempie a strisce verticali: il profilo dell'arco esce esatto
## per costruzione, senza dover triangolare un poligono concavo.
func _draw_facade(canvas: Control, s: Vector2, cx: float, half: float, rise: float) -> void:
	var step := 4.0
	var x := 0.0
	while x < s.x:
		var bottom := _facade_bottom(x + step * 0.5, cx, half, rise)
		canvas.draw_rect(Rect2(Vector2(x, FACADE_TOP), Vector2(step + 1.0, bottom - FACADE_TOP)), Style.STONE)
		x += step

	# Corsi orizzontali e giunti sfalsati: bastano poche linee di malta per
	# trasformare una campitura piatta in pietra squadrata.
	var row := 0
	var y := FACADE_TOP + 30.0
	while y < SPRING_Y:
		var open_half := _opening_half(y, half, rise)
		canvas.draw_line(Vector2(0.0, y), Vector2(cx - open_half, y), Style.MORTAR, 2.0)
		canvas.draw_line(Vector2(cx + open_half, y), Vector2(s.x, y), Style.MORTAR, 2.0)

		var joint := 34.0 + (row % 2) * 36.0
		while joint < s.x:
			if absf(joint - cx) > open_half + 8.0:
				var stop: float = minf(y + 30.0, _facade_bottom(joint, cx, half, rise))
				canvas.draw_line(Vector2(joint, y), Vector2(joint, stop), Style.MORTAR, 2.0)
			joint += 72.0

		row += 1
		y += 30.0


## Le due colonne. Il lato interno è schiarito e quello esterno incupito: è
## l'unico modo, senza gradienti, per far sembrare tonda una campitura piatta.
func _draw_columns(canvas: Control, s: Vector2) -> void:
	var base_top := s.y - FLOOR_H - 64.0

	for side in range(2):
		var x0: float = 0.0 if side == 0 else s.x - COLUMN_W
		var inner: float = x0 + COLUMN_W - 7.0 if side == 0 else x0
		var outer: float = x0 if side == 0 else x0 + COLUMN_W - 9.0

		canvas.draw_rect(Rect2(Vector2(x0, SPRING_Y), Vector2(COLUMN_W, s.y - SPRING_Y)), Style.STONE)
		canvas.draw_rect(Rect2(Vector2(outer, SPRING_Y), Vector2(9.0, s.y - SPRING_Y)), Style.STONE_DARK)
		canvas.draw_rect(Rect2(Vector2(inner, SPRING_Y), Vector2(7.0, s.y - SPRING_Y)), Style.STONE_LIT)

		# Scanalature: il dettaglio che distingue una colonna da un pilastro.
		for i in range(3):
			var fx := x0 + COLUMN_W * (0.28 + 0.22 * i)
			canvas.draw_line(Vector2(fx, SPRING_Y + 36.0), Vector2(fx, base_top - 6.0), Style.MORTAR, 2.0)

		# Capitello sotto l'imposta dell'arco e base sopra il pavimento: senza,
		# le colonne sembrerebbero due strisce tagliate dai bordi dello schermo.
		canvas.draw_rect(Rect2(Vector2(x0 - 12.0, SPRING_Y - 8.0), Vector2(COLUMN_W + 24.0, 12.0)), Style.STONE_LIT)
		canvas.draw_rect(Rect2(Vector2(x0 - 7.0, SPRING_Y + 4.0), Vector2(COLUMN_W + 14.0, 22.0)), Style.STONE)
		canvas.draw_line(Vector2(x0 - 7.0, SPRING_Y + 26.0), Vector2(x0 + COLUMN_W + 7.0, SPRING_Y + 26.0), Style.MORTAR, 2.0)

		canvas.draw_rect(Rect2(Vector2(x0 - 7.0, base_top), Vector2(COLUMN_W + 14.0, 26.0)), Style.STONE)
		canvas.draw_rect(Rect2(Vector2(x0 - 12.0, base_top + 26.0), Vector2(COLUMN_W + 24.0, s.y - base_top - 26.0)), Style.STONE_LIT.darkened(0.3))

		# Scudo appeso al fusto: un fermo per l'occhio a metà colonna, dove
		# altrimenti resterebbe mezzo schermo di pietra vuota.
		var sy := (SPRING_Y + base_top) * 0.5
		var mid := x0 + COLUMN_W * 0.5
		canvas.draw_circle(Vector2(mid, sy), 18.0, Style.STONE_DARK)
		canvas.draw_circle(Vector2(mid, sy), 15.0, Style.GOLD_DEEP.darkened(0.45))
		canvas.draw_line(Vector2(mid - 10.0, sy), Vector2(mid + 10.0, sy), Style.GOLD_DEEP, 3.0)
		canvas.draw_line(Vector2(mid, sy - 10.0), Vector2(mid, sy + 10.0), Style.GOLD_DEEP, 3.0)


## Ghiera dell'arco: conci radiali, chiave di volta e un filo d'oro sul bordo,
## che è quello che fa leggere l'ingresso come una porta cerimoniale.
func _draw_arch(canvas: Control, cx: float, half: float, rise: float) -> void:
	var segments := 28
	var curve := PackedVector2Array()
	for i in range(segments + 1):
		var t: float = PI - PI * i / float(segments)
		curve.append(Vector2(cx + cos(t) * half, SPRING_Y - sin(t) * rise))

	for i in range(2, segments - 1, 2):
		var p: Vector2 = curve[i]
		var dir := (p - Vector2(cx, SPRING_Y)).normalized()
		canvas.draw_line(p, p + dir * 30.0, Style.MORTAR, 2.0)

	canvas.draw_polyline(curve, Style.MORTAR, 4.0, true)
	canvas.draw_polyline(curve, Style.GOLD_DEEP.darkened(0.1), 2.0, true)

	var crown := SPRING_Y - rise
	var keystone := PackedVector2Array([
		Vector2(cx - 17.0, crown + 6.0),
		Vector2(cx + 17.0, crown + 6.0),
		Vector2(cx + 25.0, crown - 32.0),
		Vector2(cx - 25.0, crown - 32.0),
	])
	canvas.draw_colored_polygon(keystone, Style.STONE_LIT)
	canvas.draw_polyline(keystone, Style.MORTAR, 2.0, true)
	canvas.draw_line(Vector2(cx, crown - 24.0), Vector2(cx, crown - 2.0), Style.GOLD_DEEP, 3.0)


## Lastricato in fondo: chiude la prospettiva sotto ai pulsanti, così le
## colonne poggiano su qualcosa invece di scendere nel vuoto.
func _draw_floor(canvas: Control, s: Vector2) -> void:
	var y := s.y - FLOOR_H
	canvas.draw_rect(Rect2(Vector2(0.0, y), Vector2(s.x, FLOOR_H)), Style.STONE.darkened(0.35))
	canvas.draw_line(Vector2(0.0, y), Vector2(s.x, y), Style.STONE_LIT, 2.0)

	# Giunti in fuga verso il centro: suggeriscono la profondità del passaggio.
	var jx := 0.0
	while jx < s.x:
		var lean: float = (jx - s.x * 0.5) / s.x * 44.0
		canvas.draw_line(Vector2(jx, y), Vector2(jx + lean, s.y), Style.MORTAR, 2.0)
		jx += 96.0


## Torce sulle colonne: l'unica sorgente calda dello schermo. Portano l'occhio
## verso il centro, dove sta il titolo, e staccano la pietra dal cielo.
func _draw_torches(canvas: Control, s: Vector2) -> void:
	for side in range(2):
		var x: float = COLUMN_W * 0.5 if side == 0 else s.x - COLUMN_W * 0.5
		var y := SPRING_Y + 168.0

		# L'alone è fatto di cerchi molto trasparenti sovrapposti: è il
		# gradiente che draw_circle non ha, e costa sei chiamate invece di una
		# texture da tenere in memoria.
		var glow := Style.TORCH
		for i in range(6):
			canvas.draw_circle(Vector2(x, y), 130.0 - i * 20.0, Color(glow.r, glow.g, glow.b, 0.035))

		# Braccio e coppa della torcia.
		canvas.draw_line(Vector2(x, y + 34.0), Vector2(x, y + 10.0), Style.STONE_DARK, 6.0)
		canvas.draw_colored_polygon(PackedVector2Array([
			Vector2(x - 16.0, y + 8.0),
			Vector2(x + 16.0, y + 8.0),
			Vector2(x + 9.0, y + 24.0),
			Vector2(x - 9.0, y + 24.0),
		]), Style.STONE_DARK)

		# Fiamma a goccia: un cerchio sembrerebbe una lampadina.
		canvas.draw_colored_polygon(PackedVector2Array([
			Vector2(x, y - 34.0),
			Vector2(x + 14.0, y - 6.0),
			Vector2(x + 10.0, y + 9.0),
			Vector2(x, y + 13.0),
			Vector2(x - 10.0, y + 9.0),
			Vector2(x - 14.0, y - 6.0),
		]), Style.TORCH)
		canvas.draw_colored_polygon(PackedVector2Array([
			Vector2(x, y - 18.0),
			Vector2(x + 7.0, y - 2.0),
			Vector2(x, y + 8.0),
			Vector2(x - 7.0, y - 2.0),
		]), Color(1.0, 0.94, 0.76))


## Il titolo su una targa d'oro invece che come testo nudo: senza asset è il
## modo più economico per dare allo schermo un centro di gravità.
func _banner() -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 12)

	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", Style.plate(Style.STONE.darkened(0.45), Style.GOLD_DEEP, 20, 8))
	wrap.add_child(plate)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", -6)
	plate.add_child(stack)

	var line_one := Label.new()
	line_one.text = "AUTOCHESS"
	line_one.add_theme_font_size_override("font_size", 54)
	line_one.add_theme_color_override("font_color", Style.GOLD)
	line_one.add_theme_color_override("font_shadow_color", Style.INK)
	line_one.add_theme_constant_override("shadow_offset_y", 4)
	line_one.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(line_one)

	var line_two := Label.new()
	line_two.text = "OF AGES"
	line_two.add_theme_font_size_override("font_size", 34)
	line_two.add_theme_color_override("font_color", Style.GOLD.darkened(0.15))
	line_two.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(line_two)

	var subtitle := Label.new()
	subtitle.text = "Legionari e Barbari"
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
	frame.add_theme_stylebox_override("panel", Style.plate(Style.STONE.darkened(0.35), Style.GOLD_DEEP, 18, 6))
	frame.custom_minimum_size = Vector2(0, HERO_VIEW_SIZE + 18)
	column.add_child(frame)

	var center := CenterContainer.new()
	frame.add_child(center)

	var viewport_container := SubViewportContainer.new()
	viewport_container.custom_minimum_size = Vector2(HERO_VIEW_SIZE, HERO_VIEW_SIZE)
	viewport_container.stretch = true
	viewport_container.mouse_filter = Control.MOUSE_FILTER_STOP
	viewport_container.gui_input.connect(_on_hero_viewport_input)
	center.add_child(viewport_container)

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
	elif event is InputEventMouseMotion and _hero_dragging:
		var mm := event as InputEventMouseMotion
		var delta_x := mm.position.x - _hero_drag_last_x
		_hero_drag_last_x = mm.position.x
		if _hero_model_root != null:
			_hero_model_root.rotate_y(deg_to_rad(delta_x) * 0.6)


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


func _on_portrait_ready(id: String) -> void:
	if id == _hero_detail_id and _hero_detail_portrait != null:
		_hero_detail_portrait.texture = get_node("/root/Portraits").hero_texture_for(id)


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
	play.text = "BATTAGLIA"
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
	title.text = "SCEGLI " + MODE_LABEL
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(title)

	column.add_child(_mode_option(MODE_CPU, "🖥️  Contro il computer",
		"Affronta subito degli avversari controllati dal gioco."))
	column.add_child(_mode_option(MODE_PVP, "👥  Contro giocatori",
		"Partita online 8 giocatori. Richiede l'accesso con Google."))

	column.add_child(_grow())

	var close := Button.new()
	close.text = "Chiudi"
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
	title.text = "SCEGLI " + HERO_LABEL
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
	close.text = "Chiudi"
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

	_hero_detail_portrait = TextureRect.new()
	_hero_detail_portrait.expand_mode = TextureRect.EXPAND_FIT_HEIGHT_PROPORTIONAL
	_hero_detail_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_hero_detail_portrait.custom_minimum_size = Vector2(0, 150)
	column.add_child(_hero_detail_portrait)

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
	back.text = "Indietro"
	back.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back.add_theme_font_size_override("font_size", 18)
	Style.apply_plate(back, Style.PLATE, Style.PLATE_DARK, 18, 6)
	back.pressed.connect(func() -> void:
		_hero_detail_panel.visible = false
		_hero_panel.visible = true)
	buttons.add_child(back)

	_hero_detail_select = Button.new()
	_hero_detail_select.text = "Seleziona"
	_hero_detail_select.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	_hero_detail_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hero_detail_select.add_theme_font_size_override("font_size", 18)
	_hero_detail_select.add_theme_color_override("font_color", Style.INK)
	Style.apply_plate(_hero_detail_select, Style.GOLD, Style.GOLD_DEEP, 18, 6)
	_hero_detail_select.pressed.connect(func() -> void: _on_hero_pressed(_hero_detail_id))
	buttons.add_child(_hero_detail_select)


func _open_hero_detail(hero_id: String) -> void:
	var hdef := GameData.hero(hero_id)
	_hero_detail_id = hero_id
	_hero_detail_name.text = hdef.display_name
	_hero_detail_origin.text = String(GameData.trait_def(hdef.origin).get("name", hdef.origin))
	_hero_detail_lore.text = hdef.lore
	_hero_detail_ability.text = hdef.ability_text
	_hero_detail_portrait.texture = get_node("/root/Portraits").hero_texture_for(hero_id)
	_hero_panel.visible = false
	_hero_detail_panel.visible = true


## Tre pulsanti invece dei due precedenti: col font ridotto a 20 restano
## dentro i loro bersagli anche con l'etichetta più lunga ("Collezione").
func _nav_bar() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	_guide_button = Button.new()
	_guide_button.text = "📖 Guida"
	_guide_button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	_guide_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_guide_button.add_theme_font_size_override("font_size", 20)
	_guide_button.pressed.connect(_on_guide_pressed)
	row.add_child(_guide_button)
	_update_guide_button()

	for entry in [["🎴 Collezione", _on_collection_pressed], ["🛒 Negozio", _on_store_pressed]]:
		var button := Button.new()
		button.text = String(entry[0])
		button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 20)
		Style.apply_plate(button, Style.BLUE, Style.BLUE_DEEP, 18, 6)
		button.pressed.connect(entry[1] as Callable)
		row.add_child(button)

	# Solo icona: non toglie larghezza alle tre voci accanto.
	var settings_button := Button.new()
	settings_button.text = "⚙️"
	settings_button.custom_minimum_size = Vector2(Style.TOUCH_MIN, Style.TOUCH_MIN)
	settings_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	settings_button.add_theme_font_size_override("font_size", 20)
	Style.apply_plate(settings_button, Style.PLATE, Style.PLATE_DARK, 18, 6)
	settings_button.pressed.connect(func() -> void: _settings_panel.open())
	row.add_child(settings_button)

	return row


## Il pulsante Guida è dorato finché non è mai stato aperto: è la seconda
## cosa che si nota all'avvio dopo BATTAGLIA, senza aprirsi da sola — una
## modale che compare al primo avvio si chiude senza essere letta.
func _update_guide_button() -> void:
	if _profile.has_seen_tip("guide_opened"):
		Style.apply_plate(_guide_button, Style.BLUE, Style.BLUE_DEEP, 18, 6)
	else:
		Style.apply_plate(_guide_button, Style.GOLD, Style.GOLD_DEEP, 18, 6)
		_guide_button.add_theme_color_override("font_color", Style.INK)


func _on_guide_pressed() -> void:
	_guide_panel.open()
	_update_guide_button()


## Titolo di sezione con un filo d'oro che corre fino al bordo: separa le
## sezioni senza aggiungere un altro pannello, e riprende la ghiera dell'arco.
func _section(text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 19)
	label.add_theme_color_override("font_color", Style.GOLD.darkened(0.2))
	row.add_child(label)

	var rule := ColorRect.new()
	rule.color = Style.GOLD_DEEP.darkened(0.25)
	rule.custom_minimum_size = Vector2(0, 2)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(rule)

	return row


func _spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


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


## Contro giocatori: serve un account. Se gia' loggati si va in lobby; se no si
## avvia il login Google e si prosegue al suo completamento. Senza l'autoload
## Auth (edge headless) si ricade sul vecchio avviso "in arrivo".
func _start_pvp() -> void:
	if DevNet.enabled():
		# Sviluppo locale: niente login, master/worker headless su 127.0.0.1.
		get_tree().change_scene_to_file(LOBBY_SCENE)
		return
	var auth := get_node_or_null("/root/Auth")
	if auth == null:
		_show_pvp_unavailable("La modalità contro giocatori arriva in un prossimo aggiornamento.")
		return
	if auth.is_logged_in():
		get_tree().change_scene_to_file(LOBBY_SCENE)
		return
	if not auth.login_completed.is_connected(_on_pvp_login_completed):
		auth.login_completed.connect(_on_pvp_login_completed, CONNECT_ONE_SHOT)
	auth.login_google()


func _on_pvp_login_completed(success: bool, reason: String) -> void:
	if success:
		get_tree().change_scene_to_file(LOBBY_SCENE)
	else:
		_show_pvp_unavailable("Accesso non riuscito: %s" % reason)


func _show_pvp_unavailable(message: String) -> void:
	var notice := AcceptDialog.new()
	notice.dialog_text = message
	notice.title = "Contro giocatori"
	add_child(notice)
	notice.confirmed.connect(notice.queue_free)
	notice.canceled.connect(notice.queue_free)
	notice.popup_centered()


func _on_collection_pressed() -> void:
	_collection_panel.open()


func _on_store_pressed() -> void:
	_store_panel.open()


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
		_mode_button.tooltip_text = "Modalità: contro giocatori"
	else:
		_mode_button.text = "🖥️"
		_mode_button.tooltip_text = "Modalità: contro il computer"

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
	_hero_button.tooltip_text = "Eroe: %s" % (hdef.display_name if hdef != null else _selected_hero)

	for hero_id in _hero_option_buttons:
		var button: Button = _hero_option_buttons[hero_id]
		var selected: bool = hero_id == _selected_hero
		Style.apply_plate(button, Style.GOLD if selected else Style.PLATE, Style.GOLD_DEEP if selected else Style.PLATE_DARK, 18, 6)
		button.add_theme_color_override("font_color", Style.INK if selected else Style.TEXT_DIM)
