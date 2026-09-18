extends SceneTree

## Rende lo sfondo dell'arena di battaglia (1024×1536) nello stesso stile dei
## modelli delle unità: primitive low-poly a tinta piatta, stesse luci e stessa
## camera ortogonale a 58° di BattleBoard3D. Il vecchio sfondo in pixel art
## stonava con le figure 3D sopra: qui fondale e unità parlano la stessa lingua.
##
##   godot --path . --script res://tools/arena_background.gd -- <file.png>
##
## Va eseguito SENZA --headless. La disposizione ricalca l'arena originale:
## accampamento romano in alto (rosso), barbaro in basso (blu), radura al
## centro dove si stende la scacchiera.

const SIZE := Vector2i(1024, 1536)
const OUT_DEFAULT := "user://battle_arena.png"
const CAMERA_PITCH := 58.0
## Larghezza di mondo inquadrata: la scacchiera di gioco occupa ~7.7 unità, e
## così le figure dello sfondo hanno la stessa scala delle unità sopra.
const VIEW_WIDTH := 9.0
## Radura: semiassi dell'ellisse di terra battuta in cui sta la scacchiera.
const CLEAR_X := 4.1
const CLEAR_Z := 5.6
const SEED := 7

const GRASS := Color(0.30, 0.46, 0.22)
const GRASS_DARK := Color(0.22, 0.36, 0.17)
const DIRT := Color(0.47, 0.38, 0.24)
const DIRT_DARK := Color(0.41, 0.32, 0.20)
## Fondo della radura: erba rasa e calpestata, fra il prato e la terra.
const MEADOW := Color(0.38, 0.45, 0.24)
const WOOD := Color(0.36, 0.25, 0.15)
const WOOD_DARK := Color(0.26, 0.18, 0.11)
const STONE := Color(0.50, 0.51, 0.54)
const STONE_DARK := Color(0.40, 0.41, 0.45)
const LEAF := [Color(0.16, 0.38, 0.17), Color(0.20, 0.44, 0.18), Color(0.13, 0.31, 0.15), Color(0.24, 0.48, 0.20)]
const ROMAN_RED := Color(0.68, 0.16, 0.14)
const GOLD := Color(0.86, 0.68, 0.26)
const CLOTH := Color(0.90, 0.87, 0.80)
const GAUL_BLUE := Color(0.20, 0.30, 0.62)

var _viewport: SubViewport
var _world: Node3D
var _frames := 0
var _out := OUT_DEFAULT
var _rng := RandomNumberGenerator.new()
var _materials := {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_rng.seed = SEED

	_viewport = SubViewport.new()
	_viewport.size = SIZE
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_8X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	_world = Node3D.new()
	_viewport.add_child(_world)
	_build_environment()
	_build_camera()
	_build_ground()
	_build_palisades()
	_build_gates()
	_build_roman_camp()
	_build_gaul_camp()
	_build_rocks()
	_build_forest()


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 12:
		var image := _viewport.get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		var error := image.save_png(_out)
		if error != OK:
			printerr("salvataggio fallito (%d): %s" % [error, _out])
			quit(1)
		else:
			print("sfondo salvato in %s" % ProjectSettings.globalize_path(_out))
			quit(0)
	return false


# --------------------------------------------------------------------------
# Scena
# --------------------------------------------------------------------------

## Stesse luci di BattleBoard3D: se lo sfondo fosse illuminato diversamente le
## unità sembrerebbero incollate sopra invece che stare nel posto.
func _build_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = GRASS_DARK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.52, 0.56, 0.68)
	environment.ambient_light_energy = 0.75
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	_world.add_child(world_environment)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-52, 38, 0)
	key.light_energy = 1.15
	key.light_color = Color(1.0, 0.96, 0.88)
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 45.0
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	key.shadow_bias = 0.08
	key.shadow_normal_bias = 1.5
	_world.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-24, -140, 0)
	fill.light_energy = 0.45
	fill.light_color = Color(0.66, 0.74, 1.0)
	_world.add_child(fill)


func _build_camera() -> void:
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.1
	camera.far = 100.0
	var pitch := deg_to_rad(CAMERA_PITCH)
	camera.position = Vector3(0, sin(pitch) * 30.0, cos(pitch) * 30.0)
	camera.rotation_degrees = Vector3(-CAMERA_PITCH, 0, 0)
	camera.size = VIEW_WIDTH * float(SIZE.y) / float(SIZE.x)
	_world.add_child(camera)
	camera.current = true


## Estensione di terreno visibile lungo Z: l'inquadratura verticale, vista di
## scorcio, copre più profondità di quanto sia alta.
func _half_depth() -> float:
	return VIEW_WIDTH * float(SIZE.y) / float(SIZE.x) / sin(deg_to_rad(CAMERA_PITCH)) * 0.5


func _inside_clearing(x: float, z: float, margin: float = 0.0) -> bool:
	var ex := x / (CLEAR_X + margin)
	var ez := z / (CLEAR_Z + margin)
	return ex * ex + ez * ez < 1.0


func _build_ground() -> void:
	_box(Vector3(0, -0.06, 0), Vector3(40, 0.1, 40), GRASS_DARK)

	# Radura: un cilindro schiacciato e stirato a ellisse. Pochi lati di
	# proposito, il bordo spigoloso è lo stesso registro delle figure.
	var clearing := _cylinder(Vector3(0, -0.03, 0), 1.0, 1.0, 0.04, MEADOW, 14)
	clearing.scale = Vector3(CLEAR_X, 1, CLEAR_Z)
	var rim := _cylinder(Vector3(0, -0.035, 0), 1.0, 1.0, 0.04, GRASS, 14)
	rim.scale = Vector3(CLEAR_X + 0.6, 1, CLEAR_Z + 0.6)

	# Sentiero dai cancelli fino al bordo della radura: si perde nella terra
	# battuta invece di tagliare in due il campo sotto la scacchiera.
	for side in [-1.0, 1.0]:
		var outer := _half_depth()
		var inner := CLEAR_Z - 0.8
		_box(Vector3(0, -0.028, side * (outer + inner) * 0.5), Vector3(1.3, 0.04, outer - inner), DIRT)

	# Terra battuta al centro, dove si combatte: un'ellisse spigolosa e poche
	# chiazze lungo il suo bordo che la sfrangiano nel prato. Pentagoni e non
	# esagoni, perché un esagono sul terreno si confonderebbe con le celle
	# della scacchiera.
	var arena := _cylinder(Vector3(0, -0.004, 0), 1.0, 1.0, 0.01, DIRT, 11)
	arena.scale = Vector3(CLEAR_X * 0.72, 1, CLEAR_Z * 0.8)
	arena.rotation_degrees.y = 8
	for i in 26:
		var angle := _rng.randf_range(0, TAU)
		var edge := _rng.randf_range(0.85, 1.12)
		var x := cos(angle) * CLEAR_X * 0.72 * edge
		var z := sin(angle) * CLEAR_Z * 0.8 * edge
		var r := _rng.randf_range(0.2, 0.45)
		var colour: Color = DIRT if edge > 1.0 else (MEADOW if _rng.randf() < 0.6 else DIRT_DARK)
		var patch := _cylinder(Vector3(x, 0.002 + 0.0002 * i, z), r, r, 0.01, colour, 5)
		patch.scale.z = _rng.randf_range(0.6, 1.1)
		patch.rotation_degrees.y = _rng.randf_range(0, 72)

	# Ciuffi e cespugli: piccole piramidi verdi, la vegetazione "low-poly".
	for i in 46:
		var x := _rng.randf_range(-CLEAR_X, CLEAR_X)
		var z := _rng.randf_range(-CLEAR_Z, CLEAR_Z)
		if not _inside_clearing(x, z, -0.2) or absf(x) < 0.8:
			continue
		_tuft(Vector3(x, 0, z), _rng.randf_range(0.10, 0.2))


func _tuft(at: Vector3, size: float) -> void:
	for k in 3:
		var offset := Vector3(_rng.randf_range(-size, size), 0, _rng.randf_range(-size, size))
		var h := size * _rng.randf_range(1.2, 2.0)
		_cylinder(at + offset + Vector3(0, h * 0.5, 0), 0.0, size * 0.55, h, LEAF[_rng.randi() % LEAF.size()], 4)


## Palizzate lungo il bordo della radura, aperte dove passa il sentiero.
func _build_palisades() -> void:
	var d := _half_depth()
	for side in [-1.0, 1.0]:
		var z_line: float = side * (d - 1.35)
		# Tratti orizzontali ai lati dei cancelli.
		_palisade_run(Vector3(-3.6, 0, z_line), Vector3(-1.05, 0, z_line))
		_palisade_run(Vector3(1.05, 0, z_line), Vector3(3.6, 0, z_line))
		# Tratti obliqui che scendono lungo i fianchi.
		_palisade_run(Vector3(-3.6, 0, z_line), Vector3(-4.3, 0, z_line - side * 2.2))
		_palisade_run(Vector3(3.6, 0, z_line), Vector3(4.3, 0, z_line - side * 2.2))
	# Spezzoni sui fianchi a metà campo, come nell'arena originale.
	for x in [-4.35, 4.35]:
		_palisade_run(Vector3(x, 0, -0.9), Vector3(x, 0, 0.9))


func _palisade_run(from: Vector3, to: Vector3) -> void:
	var length := from.distance_to(to)
	var count := int(length / 0.2) + 1
	for i in count:
		var t := float(i) / maxf(float(count - 1), 1.0)
		var p := from.lerp(to, t)
		var h := 0.55 + 0.08 * sin(float(i) * 2.3)
		var colour := WOOD if i % 2 == 0 else WOOD_DARK
		_cylinder(p + Vector3(0, h * 0.5, 0), 0.075, 0.085, h, colour, 6)
		_cylinder(p + Vector3(0, h + 0.07, 0), 0.0, 0.075, 0.14, colour, 6)
	# Traversa orizzontale che lega i pali.
	var mid := (from + to) * 0.5 + Vector3(0, 0.34, 0)
	var rail := _box(mid, Vector3(length, 0.05, 0.05), WOOD_DARK)
	rail.rotation.y = -atan2(to.z - from.z, to.x - from.x)


## Cancelli: due pilastri con braciere e stendardo, rosso in alto, blu in basso.
func _build_gates() -> void:
	var d := _half_depth()
	for side in [-1.0, 1.0]:
		var z: float = side * (d - 1.35)
		var banner: Color = ROMAN_RED if side < 0 else GAUL_BLUE
		for x in [-0.8, 0.8]:
			_cylinder(Vector3(x, 0.45, z), 0.16, 0.18, 0.9, STONE_DARK, 8)
			_cylinder(Vector3(x, 0.94, z), 0.24, 0.14, 0.12, WOOD_DARK, 8)
			_brazier_fire(Vector3(x, 1.0, z))
			var flag := _box(Vector3(x, 0.5, z + 0.19), Vector3(0.22, 0.5, 0.03), banner)
			flag.rotation_degrees.x = 0
			_box(Vector3(x, 0.52, z + 0.21), Vector3(0.08, 0.08, 0.02), GOLD if side < 0 else CLOTH)
		# Gradini di legno nel varco.
		for k in 3:
			_box(Vector3(0, 0.02 + 0.02 * k, z - side * 0.2 * k), Vector3(1.2, 0.04, 0.16), WOOD)


func _brazier_fire(at: Vector3) -> void:
	_cylinder(at + Vector3(0, 0.08, 0), 0.0, 0.14, 0.2, Color(1.0, 0.55, 0.12), 5, true)
	_cylinder(at + Vector3(0, 0.1, 0), 0.0, 0.08, 0.16, Color(1.0, 0.86, 0.35), 5, true)
	var light := OmniLight3D.new()
	light.position = at + Vector3(0, 0.3, 0)
	light.light_color = Color(1.0, 0.6, 0.25)
	light.light_energy = 0.8
	light.omni_range = 1.0
	_world.add_child(light)


## Accampamento romano (lontano dalla camera): tenda a strisce bianche e rosse,
## stendardi porpora con l'aquila d'oro, braciere e casse.
func _build_roman_camp() -> void:
	var z0 := -_half_depth()
	_standard(Vector3(-3.9, 0, z0 + 1.3), ROMAN_RED, GOLD, 1.9)
	_standard(Vector3(3.9, 0, z0 + 1.3), ROMAN_RED, GOLD, 1.9)
	_standard(Vector3(-2.6, 0, z0 + 2.05), ROMAN_RED, GOLD, 1.2)
	_tent(Vector3(-2.3, 0, z0 + 1.55), ROMAN_RED, CLOTH)
	_hut(Vector3(2.7, 0, z0 + 1.6))
	_brazier(Vector3(-1.5, 0, z0 + 2.35))
	_brazier(Vector3(2.9, 0, z0 + 2.45))
	_crate(Vector3(-3.1, 0, z0 + 2.4))
	_barrel(Vector3(-1.8, 0, z0 + 2.2))
	_crate(Vector3(3.8, 0, z0 + 3.4))


## Accampamento barbaro (vicino alla camera): tenda a strisce blu, stendardi con
## il triskele, un menhir inciso.
func _build_gaul_camp() -> void:
	var z0 := _half_depth()
	_standard(Vector3(-3.9, 0, z0 - 2.3), GAUL_BLUE, CLOTH, 1.5)
	_standard(Vector3(3.9, 0, z0 - 2.3), GAUL_BLUE, CLOTH, 1.5)
	_tent(Vector3(2.7, 0, z0 - 1.9), GAUL_BLUE, CLOTH)
	_menhir(Vector3(-3.3, 0, z0 - 1.8))
	_brazier(Vector3(1.6, 0, z0 - 2.25))
	_barrel(Vector3(1.95, 0, z0 - 2.0))
	_crate(Vector3(-2.4, 0, z0 - 2.4))
	_crate(Vector3(-2.2, 0, z0 - 2.1))


func _standard(at: Vector3, colour: Color, emblem: Color, height: float) -> void:
	_cylinder(at + Vector3(0, height * 0.5, 0), 0.03, 0.035, height, WOOD_DARK, 6)
	_box(at + Vector3(0, height - 0.03, 0.03), Vector3(0.62, 0.04, 0.04), GOLD)
	var h := height * 0.45
	_box(at + Vector3(0, height - 0.06 - h * 0.5, 0.06), Vector3(0.52, h, 0.03), colour)
	# Emblema: un rombo, leggibile dall'alto più di qualsiasi disegno fine.
	var gem := _box(at + Vector3(0, height - 0.06 - h * 0.45, 0.08), Vector3(0.18, 0.18, 0.02), emblem)
	gem.rotation_degrees.z = 45
	# Coda a punta sotto il drappo.
	var tip := _box(at + Vector3(0, height - 0.06 - h, 0.06), Vector3(0.26, 0.26, 0.03), colour)
	tip.rotation_degrees.z = 45
	_box(at + Vector3(0, height - 0.04, 0.06), Vector3(0.56, 0.05, 0.035), emblem)


func _tent(at: Vector3, stripe: Color, base: Color) -> void:
	# Tetto a spicchi alterni: due coni a quattro lati ruotati di 45° uno
	# rispetto all'altro, così le falde colorate si alternano come le strisce
	# di una tenda da campo, leggibili anche dall'alto.
	_cylinder(at + Vector3(0, 0.22, 0), 0.56, 0.6, 0.44, base, 8)
	var roof_a := _cylinder(at + Vector3(0, 0.7, 0), 0.0, 0.8, 0.52, stripe, 4)
	roof_a.rotation_degrees.y = 0
	var roof_b := _cylinder(at + Vector3(0, 0.7, 0), 0.0, 0.8, 0.52, base, 4)
	roof_b.rotation_degrees.y = 45
	_box(at + Vector3(0, 0.18, 0.6), Vector3(0.24, 0.34, 0.04), WOOD_DARK)
	_cylinder(at + Vector3(0, 1.05, 0), 0.02, 0.02, 0.3, WOOD_DARK, 5)
	var pennant := _box(at + Vector3(0.1, 1.15, 0), Vector3(0.18, 0.1, 0.02), stripe)
	pennant.rotation_degrees.z = -8


func _hut(at: Vector3) -> void:
	_box(at + Vector3(0, 0.25, 0), Vector3(1.0, 0.5, 0.8), WOOD)
	var roof_l := _box(at + Vector3(-0.27, 0.66, 0), Vector3(0.66, 0.06, 1.0), WOOD_DARK)
	roof_l.rotation_degrees.z = 32
	var roof_r := _box(at + Vector3(0.27, 0.66, 0), Vector3(0.66, 0.06, 1.0), Color(0.31, 0.22, 0.13))
	roof_r.rotation_degrees.z = -32
	_box(at + Vector3(0, 0.2, 0.41), Vector3(0.22, 0.36, 0.03), WOOD_DARK)


func _brazier(at: Vector3) -> void:
	_cylinder(at + Vector3(0, 0.12, 0), 0.12, 0.08, 0.24, STONE_DARK, 6)
	_brazier_fire(at + Vector3(0, 0.22, 0))


func _crate(at: Vector3) -> void:
	var c := _box(at + Vector3(0, 0.14, 0), Vector3(0.28, 0.28, 0.28), WOOD)
	c.rotation_degrees.y = _rng.randf_range(-20, 20)
	var band := _box(at + Vector3(0, 0.285, 0), Vector3(0.3, 0.02, 0.06), WOOD_DARK)
	band.rotation_degrees.y = c.rotation_degrees.y


func _barrel(at: Vector3) -> void:
	_cylinder(at + Vector3(0, 0.16, 0), 0.13, 0.13, 0.32, WOOD, 8)
	_cylinder(at + Vector3(0, 0.26, 0), 0.135, 0.135, 0.03, WOOD_DARK, 8)
	_cylinder(at + Vector3(0, 0.08, 0), 0.135, 0.135, 0.03, WOOD_DARK, 8)


func _menhir(at: Vector3) -> void:
	var stone := _cylinder(at + Vector3(0, 0.7, 0), 0.2, 0.34, 1.4, STONE, 5)
	stone.scale.z = 0.7
	# Spirale incisa: anelli piatti sulla faccia, un disco nell'altro.
	for r in [0.16, 0.10, 0.045]:
		var ring := _cylinder(at + Vector3(0, 0.75, 0.2 + (0.16 - r) * 0.05), r, r, 0.02, STONE_DARK if r != 0.10 else STONE, 10)
		ring.rotation_degrees.x = 80


func _build_rocks() -> void:
	var spots := [
		Vector3(-3.4, 0, -3.6), Vector3(-3.7, 0, -1.8), Vector3(-3.3, 0, 1.4),
		Vector3(3.5, 0, -3.3), Vector3(3.2, 0, -2.3), Vector3(3.6, 0, 2.3),
		Vector3(2.6, 0, 4.4), Vector3(-2.9, 0, 4.3), Vector3(0.9, 0, -4.9),
	]
	for spot in spots:
		for k in _rng.randi_range(1, 3):
			var s := _rng.randf_range(0.14, 0.3)
			var p: Vector3 = spot + Vector3(_rng.randf_range(-0.3, 0.3), s * 0.45, _rng.randf_range(-0.3, 0.3))
			var rock := _sphere(p, s, STONE if _rng.randf() < 0.5 else STONE_DARK)
			rock.scale = Vector3(1.0, 0.75, _rng.randf_range(0.8, 1.2))
			rock.rotation_degrees.y = _rng.randf_range(0, 90)


## Bosco tutt'intorno: alberi a cupole sfaccettate, fitti fuori dalla radura.
func _build_forest() -> void:
	var d := _half_depth() + 1.0
	var tries := 0
	var placed: Array[Vector3] = []
	while tries < 2600:
		tries += 1
		var x := _rng.randf_range(-VIEW_WIDTH * 0.5 - 0.6, VIEW_WIDTH * 0.5 + 0.6)
		var z := _rng.randf_range(-d, d)
		# Niente alberi nella radura, sul sentiero dei cancelli e sugli
		# accampamenti: le palizzate delimitano l'area libera.
		if _inside_clearing(x, z, 0.55):
			continue
		if absf(x) < 1.3:
			continue
		if absf(x) < 4.1 and absf(z) > _half_depth() - 3.6 and absf(z) < _half_depth() - 0.9:
			continue
		var r := _rng.randf_range(0.34, 0.55)
		var crowded := false
		for other in placed:
			if Vector2(other.x - x, other.z - z).length() < (r + other.y) * 0.72:
				crowded = true
				break
		if crowded:
			continue
		placed.append(Vector3(x, r, z))
		_tree(Vector3(x, 0, z), r)


func _tree(at: Vector3, r: float) -> void:
	_cylinder(at + Vector3(0, 0.25, 0), 0.06, 0.09, 0.5, WOOD_DARK, 6)
	var colour: Color = LEAF[_rng.randi() % LEAF.size()]
	var crown := _sphere(at + Vector3(0, 0.45 + r * 0.7, 0), r, colour)
	crown.scale.y = 0.85
	# Seconda cupola più piccola e più chiara: dà volume alla chioma vista
	# dall'alto, dove una sfera sola sembra un disco.
	var top := _sphere(at + Vector3(r * 0.2, 0.55 + r * 1.2, r * 0.15), r * 0.6, colour.lightened(0.12))
	top.scale.y = 0.85


# --------------------------------------------------------------------------
# Primitive
# --------------------------------------------------------------------------

func _material(colour: Color, emissive: bool = false) -> StandardMaterial3D:
	var key := "%s_%s" % [colour.to_html(), emissive]
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness = 0.85
	if emissive:
		mat.emission_enabled = true
		mat.emission = colour
		mat.emission_energy_multiplier = 1.4
	_materials[key] = mat
	return mat


func _box(at: Vector3, size: Vector3, colour: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _add(mesh, at, colour)


func _cylinder(at: Vector3, top: float, bottom: float, height: float, colour: Color, sides: int, emissive: bool = false) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top
	mesh.bottom_radius = bottom
	mesh.height = height
	mesh.radial_segments = sides
	mesh.rings = 1
	return _add(mesh, at, colour, emissive)


## Sfera a pochi segmenti: le facce restano visibili, come nelle figure.
func _sphere(at: Vector3, radius: float, colour: Color) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 7
	mesh.rings = 4
	return _add(mesh, at, colour)


func _add(mesh: Mesh, at: Vector3, colour: Color, emissive: bool = false) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = _material(colour, emissive)
	node.position = at
	# Il terreno (lastre sottili) non proietta ombre: su superfici quasi
	# complanari l'ombra di una sull'altra produce strisce, non volume.
	if mesh.get_aabb().size.y <= 0.1:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(node)
	return node
