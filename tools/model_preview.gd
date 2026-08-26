extends Node3D

## Vetrina dei modelli: schiera tutte le unità di data/units.json in griglia,
## una riga per civiltà, con la stessa camera dall'alto della battaglia.
##
## Serve a giudicare le silhouette senza dover giocare una partita: è lì che si
## vede se due unità si confondono. Non fa parte del gioco — si apre a mano
## dall'editor, oppure con:
##   godot --path . tools/model_preview.tscn

const SPACING := 1.5
const ROW_SPACING := 2.0
const ORIGIN_ORDER := ["roman", "gaul", "teuton"]

var _camera: Camera3D
var _pitch: float = 62.0
var _yaw: float = 0.0
var _zoom: float = 1.0
var _centre := Vector3.ZERO
var _needed_width: float = 10.0
var _needed_height: float = 6.0


func _ready() -> void:
	_build_environment()
	_build_units()
	_build_camera()


func _build_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.09, 0.10, 0.13)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.52, 0.56, 0.68)
	environment.ambient_light_energy = 0.75
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-52, 38, 0)
	key.light_energy = 1.15
	key.shadow_enabled = true
	add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-24, -140, 0)
	fill.light_energy = 0.45
	fill.light_color = Color(0.66, 0.74, 1.0)
	add_child(fill)


## Con un argomento da riga di comando si mostra una sola civiltà, ingrandita:
## le silhouette si giudicano da vicino, non su venti miniature affiancate.
##   godot --path . tools/model_preview.tscn -- gaul
func _origins_to_show() -> Array:
	for argument in OS.get_cmdline_user_args():
		if ORIGIN_ORDER.has(argument):
			return [argument]
	return ORIGIN_ORDER


func _build_units() -> void:
	var by_origin := {}
	for def in GameData.all_units():
		by_origin.get_or_add(def.origin, []).append(def)

	var row := 0
	var widest := 0
	for origin in _origins_to_show():
		var defs: Array = by_origin.get(origin, [])
		if defs.is_empty():
			continue
		defs.sort_custom(func(a, b): return a.cost < b.cost or (a.cost == b.cost and a.id < b.id))
		widest = maxi(widest, defs.size())
		var z := float(row) * ROW_SPACING

		for i in defs.size():
			var def: UnitDef = defs[i]
			var x := (float(i) - float(defs.size() - 1) * 0.5) * SPACING

			# Piastrella sotto ogni modello: senza un piano di appoggio le
			# figure sembrano galleggiare e le proporzioni ingannano.
			var tile := MeshInstance3D.new()
			var tile_mesh := BoxMesh.new()
			tile_mesh.size = Vector3(1.2, 0.06, 1.2)
			tile.mesh = tile_mesh
			var tile_material := StandardMaterial3D.new()
			tile_material.albedo_color = Color(0.17, 0.19, 0.24)
			tile.material_override = tile_material
			tile.position = Vector3(x, -0.03, z)
			add_child(tile)

			var model := UnitModels.build(def.id, def.origin)
			model.position = Vector3(x, 0, z)
			add_child(model)

			var label := Label3D.new()
			label.text = "%s\n%s · %d★" % [def.display_name, UnitModels.archetype_of(def.id), def.cost]
			label.font_size = 48
			label.pixel_size = 0.0016
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.modulate = Color(0.88, 0.90, 0.96)
			label.outline_size = 12
			# L'etichetta sta davanti alla piastrella, non sopra la testa:
			# sovrapposta al modello coprirebbe proprio la silhouette che serve
			# giudicare.
			label.position = Vector3(x, 0.05, z + 0.78)
			add_child(label)

		row += 1

	_centre = Vector3(0, 0.35, float(row - 1) * ROW_SPACING * 0.5)
	_needed_width = float(widest) * SPACING + 0.8
	_needed_height = float(row) * ROW_SPACING * sin(deg_to_rad(_pitch)) + 1.4


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.far = 200.0
	add_child(_camera)
	# Inquadratura che riempie la finestra: `size` è l'estensione verticale, e
	# la larghezza va convertita passando per le proporzioni del viewport.
	var viewport_size := get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	_zoom = maxf(_needed_height, _needed_width / maxf(aspect, 0.01))
	_update_camera()


func _update_camera() -> void:
	var pitch := deg_to_rad(_pitch)
	var yaw := deg_to_rad(_yaw)
	var direction := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	_camera.position = _centre + direction * 40.0
	_camera.look_at(_centre, Vector3.UP)
	_camera.size = _zoom


## Comandi minimi per ispezionare i modelli: trascinare col mouse ruota,
## la rotella avvicina. Serve a controllare le silhouette da angolazioni
## diverse da quella di gioco.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_yaw -= event.relative.x * 0.4
		_pitch = clampf(_pitch + event.relative.y * 0.3, 5.0, 89.0)
		_update_camera()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = maxf(_zoom * 0.9, 1.0)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = minf(_zoom * 1.1, 80.0)
			_update_camera()
