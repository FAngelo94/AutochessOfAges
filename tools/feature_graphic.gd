extends SceneTree

## Genera l'immagine in primo piano della scheda Google Play (1024×500).
##
##   godot --path . --script res://tools/feature_graphic.gd -- <file.png>
##
## Come tests/screenshot.gd va eseguito SENZA --headless: il viewport deve
## renderizzare davvero. La scena usa i modelli veri del gioco (UnitModels):
## l'immagine resta coerente con ciò che il giocatore vedrà, e si rigenera da
## sola quando i modelli cambiano.

const SIZE := Vector2i(1024, 500)
const CAMERA_POS := Vector3(0, 1.55, 7.2)
const CAMERA_TARGET := Vector3(0, 0.95, 0.0)
const OUT_DEFAULT := "user://feature_graphic.png"

## Schieramenti: [id, origine, x, z]. Roma a sinistra guarda verso +X, i
## barbari a destra verso -X. Le prime linee si toccano al centro, sotto il
## titolo: lo scontro è il soggetto, il cielo sopra resta al logo.
const LEFT_ARMY := [
	["legionarius", "roman", -0.75, 2.3],
	["cesare", "hero", -1.7, 1.6],
	["centurio", "roman", -1.3, 3.2],
	["legionarius", "roman", -0.9, 0.7],
	["cataphractus", "roman", -2.7, 2.7],
	["equites", "roman", -3.0, 0.6],
	["sagittarius", "roman", -3.7, 3.1],
	["ballistarius", "roman", -4.6, -1.6],
	["velites", "roman", -2.2, -0.4],
	["legionarius", "roman", -4.0, -0.6],
	["sagittarius", "roman", -3.4, 1.4],
]
const RIGHT_ARMY := [
	["gaul_champion", "gaul", 0.75, 2.3],
	["vercingetorige", "hero", 1.7, 1.6],
	["shieldmaiden", "teuton", 1.3, 3.2],
	["clansman", "gaul", 0.9, 0.7],
	["teutobod", "hero", 2.7, 1.1],
	["chariot", "gaul", 3.4, -0.6],
	["teuton_spearman", "teuton", 3.9, 1.6],
	["gaul_druid", "gaul", 3.4, 3.4],
	["solduros", "gaul", 2.2, -0.4],
	["battering_ram", "teuton", 5.0, -1.8],
	["seeress", "teuton", 3.9, 2.9],
]

var _viewport: SubViewport
var _frames := 0
var _out := OUT_DEFAULT


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]

	_viewport = SubViewport.new()
	_viewport.size = SIZE
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_8X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	var world := Node3D.new()
	_viewport.add_child(world)
	_build_environment(world)
	_build_ground(world)
	_build_army(world, LEFT_ARMY, 90.0)
	_build_army(world, RIGHT_ARMY, -90.0)
	_build_camera(world)
	_viewport.add_child(_build_overlay())


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 12:
		var image := _viewport.get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		_apply_vignette(image)
		var error := image.save_png(_out)
		if error != OK:
			printerr("salvataggio fallito (%d): %s" % [error, _out])
			quit(1)
		else:
			print("immagine salvata in %s" % ProjectSettings.globalize_path(_out))
			quit(0)
	return false


## Vignetta applicata ai pixel dopo la cattura: un TextureRect semitrasparente
## sopra il 3D non si fonde in modo affidabile col renderer Compatibility.
## Scurisce i bordi e soprattutto il fondo, così lo sguardo va al centro, che
## è anche la zona che Google Play non ritaglia mai.
func _apply_vignette(image: Image) -> void:
	var w := image.get_width()
	var h := image.get_height()
	for y in h:
		var ny := (float(y) / h - 0.40) / 0.75
		for x in w:
			var nx := (float(x) / w - 0.5) / 0.62
			var d := sqrt(nx * nx + ny * ny)
			var k := 1.0 - 0.8 * smoothstep(0.35, 1.1, d)
			var c := image.get_pixel(x, y)
			image.set_pixel(x, y, Color(c.r * k, c.g * k, c.b * k))


func _build_environment(world: Node3D) -> void:
	# Cielo al tramonto: la luce calda radente è il registro "epico", e il blu
	# notte in alto riprende il fondo dell'icona.
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.06, 0.07, 0.13)
	sky_material.sky_horizon_color = Color(0.78, 0.34, 0.12)
	sky_material.sky_curve = 0.05
	sky_material.ground_horizon_color = Color(0.50, 0.22, 0.10)
	sky_material.ground_bottom_color = Color(0.05, 0.05, 0.07)
	sky_material.sun_angle_max = 0.0
	var sky := Sky.new()
	sky.sky_material = sky_material

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.45, 0.42, 0.55)
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.50, 0.22, 0.10)
	environment.fog_density = 0.02
	environment.fog_sky_affect = 0.0
	environment.glow_enabled = false
	environment.glow_intensity = 0.6
	environment.glow_bloom = 0.08
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world.add_child(world_environment)

	# Sole basso alle spalle degli eserciti: controluce che disegna i bordi.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-24, 180, 0)
	sun.light_color = Color(1.0, 0.72, 0.42)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	world.add_child(sun)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, 20, 0)
	key.light_color = Color(1.0, 0.90, 0.78)
	key.light_energy = 0.75
	world.add_child(key)

	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-30, -150, 0)
	rim.light_color = Color(0.45, 0.55, 1.0)
	rim.light_energy = 0.5
	world.add_child(rim)

	# Bracieri ai due lati del centro: un punto caldo che attira l'occhio.
	for x in [-0.6, 0.6]:
		var fire := OmniLight3D.new()
		fire.position = Vector3(x, 1.2, 3.2)
		fire.light_color = Color(1.0, 0.55, 0.2)
		fire.light_energy = 1.4
		fire.omni_range = 3.0
		world.add_child(fire)


## Campo esagonale come quello di gioco, ma in pietra scura: si riconosce la
## scacchiera senza che le piastrelle rubino la scena alle figure.
func _build_ground(world: Node3D) -> void:
	var base := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(600, 600)
	base.mesh = plane
	var base_material := StandardMaterial3D.new()
	base_material.albedo_color = Color(0.16, 0.12, 0.09)
	base_material.roughness = 1.0
	base.material_override = base_material
	base.position.y = -0.06
	world.add_child(base)

	var tile_mesh := CylinderMesh.new()
	tile_mesh.top_radius = 0.54
	tile_mesh.bottom_radius = 0.56
	tile_mesh.height = 0.08
	tile_mesh.radial_segments = 6
	tile_mesh.rings = 1
	var materials := [Color(0.15, 0.13, 0.13), Color(0.11, 0.10, 0.10)]
	var dx := sqrt(3.0) * 0.58
	var dz := 1.5 * 0.58
	for row in range(-40, 7):
		for col in range(-22, 23):
			var x := float(col) * dx + (dx * 0.5 if row % 2 != 0 else 0.0)
			var z := float(row) * dz
			var tile := MeshInstance3D.new()
			tile.mesh = tile_mesh
			var mat := StandardMaterial3D.new()
			mat.albedo_color = materials[(row + col) & 1]
			mat.roughness = 0.9
			tile.material_override = mat
			tile.position = Vector3(x, -0.04, z)
			tile.rotation_degrees.y = 30.0
			world.add_child(tile)


func _build_army(world: Node3D, army: Array, facing: float) -> void:
	for entry in army:
		var id: String = entry[0]
		var model: Node3D
		if entry[1] == "hero":
			model = UnitModels.build_hero(id)
		else:
			model = UnitModels.build(id, entry[1])
		model.position = Vector3(entry[2], 0, entry[3])
		# Una leggera variazione d'angolo: una fila perfettamente allineata
		# sembra una vetrina, non un esercito che avanza.
		model.rotation_degrees.y = facing + fmod(entry[2] * 37.0 + entry[3] * 11.0, 16.0) - 8.0
		world.add_child(model)


func _build_camera(world: Node3D) -> void:
	var camera := Camera3D.new()
	camera.fov = 40.0
	world.add_child(camera)
	# look_at() pretende il nodo già nell'albero, e in _initialize non lo è.
	camera.transform = Transform3D.IDENTITY.looking_at(CAMERA_TARGET - CAMERA_POS, Vector3.UP).translated(CAMERA_POS)
	camera.current = true


func _build_overlay() -> Control:
	var overlay := Control.new()
	overlay.size = Vector2(SIZE)

	var logo := TextureRect.new()
	logo.texture = load("res://art/splash/boot_logo.png")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.size = Vector2(96, 96)
	logo.position = Vector2((SIZE.x - 96) * 0.5, 12)
	overlay.add_child(logo)

	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Trajan Pro", "Cinzel", "Georgia", "Times New Roman", "serif"])
	font.font_weight = 700

	overlay.add_child(_title_label("AUTOCHESS", font, 66, 98, Style.GOLD))
	overlay.add_child(_title_label("OF AGES", font, 36, 168, Style.GOLD.darkened(0.1)))
	return overlay


func _title_label(text: String, font: Font, font_size: int, y: float, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Style.INK)
	label.add_theme_constant_override("outline_size", 14)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	label.add_theme_constant_override("shadow_offset_x", 0)
	label.add_theme_constant_override("shadow_offset_y", 5)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(0, y)
	label.size = Vector2(SIZE.x, font_size + 20)
	return label
