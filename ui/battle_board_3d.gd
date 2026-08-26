class_name BattleBoard3D
extends Node3D

## Il mondo 3D della battaglia: scacchiera, luci, camera dall'alto e i nodi
## delle unità in campo.
##
## Non conosce il log di combattimento né il tempo: riceve posizioni e stati da
## CombatView e si limita a metterli in scena. La separazione serve a poter
## cambiare la resa (angolo, materiali, effetti) senza toccare la logica di
## riproduzione, e a poter riusare la scacchiera nella schermata di
## preparazione quando ci arriveremo.

## Passo fra due colonne, in unità di mondo. Tutte le misure dei modelli sono
## tarate su questo valore: cambiarlo scala il campo ma non le figure.
const CELL := 1.0
const TILE_GAP := 0.06
const TILE_HEIGHT := 0.08

## Raggio dell'esagono (centro-vertice). Per esagoni con la punta in alto la
## larghezza è √3·R, e la vogliamo pari al passo fra colonne: R = CELL / √3.
const HEX_RADIUS := CELL * 0.57735026919

## Inclinazione della camera rispetto al piano: 90° sarebbe una pianta pura,
## in cui le figure diventano macchie illeggibili. A 62° si vede ancora la
## faccia delle unità ma la lettura tattica resta quella di una scacchiera.
const CAMERA_PITCH := 58.0
const CAMERA_MARGIN := 0.9

const OWN_COLOR := Color(0.40, 0.80, 0.45)
const ENEMY_COLOR := Color(0.92, 0.42, 0.38)

const TILE_OWN := Color(0.16, 0.19, 0.24)
const TILE_ENEMY := Color(0.22, 0.16, 0.17)
const TILE_EDGE := Color(0.30, 0.32, 0.38)

var columns: int = 7
var rows: int = 8

## Se vero la riga 0 finisce in fondo: è il capovolgimento che tiene sempre la
## squadra di chi guarda nella metà vicina alla camera.
var flip: bool = false
var viewer_team: int = 0

var camera: Camera3D

var _tiles: Node3D
var _units_root: Node3D
## uid -> {pivot, model, base, ring, height}
var _units: Dictionary = {}


func _ready() -> void:
	_build_environment()
	_tiles = Node3D.new()
	_tiles.name = "Tiles"
	add_child(_tiles)
	_units_root = Node3D.new()
	_units_root.name = "Units"
	add_child(_units_root)
	_build_camera()
	_build_tiles()


# --------------------------------------------------------------------------
# Costruzione del mondo
# --------------------------------------------------------------------------

func _build_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.07, 0.08, 0.10)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.52, 0.56, 0.68)
	# Ambiente generoso: con una sola direzionale i lati in ombra delle figure
	# diventerebbero neri e la silhouette si spezzerebbe.
	environment.ambient_light_energy = 0.75

	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	# Luce principale da dietro-sinistra rispetto alla camera: le ombre cadono
	# verso lo spettatore e staccano le unità dalla scacchiera.
	var key := DirectionalLight3D.new()
	key.name = "KeyLight"
	key.rotation_degrees = Vector3(-52, 38, 0)
	key.light_energy = 1.15
	key.light_color = Color(1.0, 0.96, 0.88)
	key.shadow_enabled = true
	add_child(key)

	# Controluce freddo, senza ombre: serve solo a disegnare un bordo sulle
	# figure rivolte dall'altra parte.
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-24, -140, 0)
	fill.light_energy = 0.45
	fill.light_color = Color(0.66, 0.74, 1.0)
	add_child(fill)


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	# Proiezione ortogonale: in una scacchiera le celle lontane devono avere la
	# stessa dimensione di quelle vicine, altrimenti la lettura delle distanze
	# — che è la sostanza di un auto battler — diventa ingannevole.
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.1
	camera.far = 100.0
	add_child(camera)
	_place_camera()


## Colloca e dimensiona la camera in modo che l'intera scacchiera entri nel
## fotogramma qualunque sia la forma del viewport.
func _place_camera() -> void:
	if camera == null:
		return
	var pitch := deg_to_rad(CAMERA_PITCH)
	var distance := 20.0
	camera.position = Vector3(0, sin(pitch) * distance, cos(pitch) * distance)
	camera.rotation_degrees = Vector3(-CAMERA_PITCH, 0, 0)

	# Larghezza: le colonne più lo sfalsamento di mezza cella delle righe
	# dispari, più un esagono intero perché la misura è da centro a centro.
	var board_width := (float(columns - 1) + 0.5) * CELL + HEX_RADIUS * 1.74 + CAMERA_MARGIN
	# La profondità del campo, vista di scorcio, occupa meno spazio verticale di
	# quanto sia lunga; l'altezza delle figure ne aggiunge un po'.
	var board_depth := float(rows - 1) * Hex.ROW_STEP_RATIO * CELL + HEX_RADIUS * 2.0
	var board_height := board_depth * sin(pitch) + cos(pitch) * 1.2 + CAMERA_MARGIN

	var viewport := get_viewport()
	var aspect := 1.0
	if viewport != null and viewport.get_visible_rect().size.y > 0.0:
		aspect = viewport.get_visible_rect().size.x / viewport.get_visible_rect().size.y
	# `size` di una camera ortogonale è l'estensione verticale: se la larghezza
	# richiesta non ci sta, si allarga finché ci entra.
	camera.size = maxf(board_height, board_width / maxf(aspect, 0.01))


## Ricostruisce la scacchiera. Va chiamata dopo aver cambiato `columns`,
## `rows` o `flip`.
func configure(new_columns: int, new_rows: int, new_flip: bool, new_viewer_team: int) -> void:
	columns = new_columns
	rows = new_rows
	flip = new_flip
	viewer_team = new_viewer_team
	if _tiles != null:
		_build_tiles()
		_place_camera()


func _build_tiles() -> void:
	for child in _tiles.get_children():
		child.queue_free()

	# Un cilindro a sei lati è un prisma esagonale: non serve costruire la mesh
	# a mano. La rotazione di 30° porta un vertice a puntare verso la camera,
	# cioè la punta in alto che la disposizione a righe sfalsate presuppone.
	var tile_mesh := CylinderMesh.new()
	tile_mesh.top_radius = HEX_RADIUS - TILE_GAP * 0.5
	tile_mesh.bottom_radius = tile_mesh.top_radius
	tile_mesh.height = TILE_HEIGHT
	tile_mesh.radial_segments = 6
	tile_mesh.rings = 1

	for y in rows:
		for x in columns:
			# La metà propria è quella che, dopo l'eventuale capovolgimento,
			# finisce vicino alla camera.
			var own_half := (y < rows / 2) if flip else (y >= rows / 2)
			var tile := MeshInstance3D.new()
			tile.mesh = tile_mesh
			tile.material_override = _tile_material(TILE_OWN if own_half else TILE_ENEMY)
			tile.position = cell_to_world(Vector2(x, y)) - Vector3(0, TILE_HEIGHT * 0.5, 0)
			tile.rotation_degrees = Vector3(0, 0, 0)
			_tiles.add_child(tile)

	# Linea di mezzeria: separa i due schieramenti come nella vista 2D.
	var divider := MeshInstance3D.new()
	var divider_mesh := BoxMesh.new()
	divider_mesh.size = Vector3((float(columns) + 0.5) * CELL, TILE_HEIGHT * 0.6, 0.05)
	divider.mesh = divider_mesh
	divider.material_override = _tile_material(TILE_EDGE)
	divider.position = Vector3(0, -TILE_HEIGHT * 0.2, 0)
	_tiles.add_child(divider)


func _tile_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.95
	return material


# --------------------------------------------------------------------------
# Coordinate
# --------------------------------------------------------------------------

## Converte una cella — anche frazionaria, durante gli spostamenti — nella
## posizione al centro della casella, sul piano del campo.
##
## Il capovolgimento per lo spettatore è una riflessione della posizione già
## calcolata, non un rovesciamento dell'indice di riga. Su una griglia
## esagonale rovesciare l'indice cambierebbe la parità delle righe, e con essa
## quali righe sono sfalsate: due celle adiacenti per il risolutore
## finirebbero disegnate come non adiacenti. Una riflessione, invece, conserva
## tutte le distanze.
func cell_to_world(cell: Vector2) -> Vector3:
	var plane := Hex.to_plane(cell)
	var x := (plane.x - _centre_offset().x) * CELL
	var z := (plane.y - _centre_offset().y) * CELL
	return Vector3(x, 0.0, -z if flip else z)


## Centro geometrico del campo, in unità di cella: le righe dispari sporgono di
## mezza cella a destra, quindi il centro non è semplicemente metà colonne.
func _centre_offset() -> Vector2:
	var half_shift := 0.25 if rows > 1 else 0.0
	return Vector2(
		float(columns - 1) * 0.5 + half_shift,
		float(rows - 1) * Hex.ROW_STEP_RATIO * 0.5
	)


## Punto sullo schermo corrispondente a una posizione nel mondo. Serve alla
## sovrimpressione 2D — barre della salute, numeri di danno — che continua a
## essere disegnata con l'API dei Control per restare nitida a ogni risoluzione.
func project(world_position: Vector3) -> Vector2:
	if camera == null:
		return Vector2.ZERO
	return camera.unproject_position(world_position)


## Posizione sopra la testa di un'unità, dove agganciare la barra della salute.
func unit_overhead(uid: int) -> Vector3:
	var entry: Dictionary = _units.get(uid, {})
	if entry.is_empty():
		return Vector3.ZERO
	var pivot: Node3D = entry["pivot"]
	return pivot.position + Vector3(0, float(entry["height"]) + 0.12, 0)


func unit_centre(uid: int) -> Vector3:
	var entry: Dictionary = _units.get(uid, {})
	if entry.is_empty():
		return Vector3.ZERO
	var pivot: Node3D = entry["pivot"]
	return pivot.position + Vector3(0, float(entry["height"]) * 0.5, 0)


# --------------------------------------------------------------------------
# Unità
# --------------------------------------------------------------------------

func clear_units() -> void:
	for child in _units_root.get_children():
		child.queue_free()
	_units.clear()


## Mette in campo un'unità. Il modello viene scelto da UnitModels in base
## all'id; la squadra si legge dal disco colorato sotto i piedi, non dalla
## tinta della figura — così la civiltà resta riconoscibile in entrambi gli
## schieramenti.
func spawn_unit(uid: int, unit_id: String, origin: String, team: int, cell: Vector2i, star: int) -> void:
	var pivot := Node3D.new()
	pivot.name = "Unit_%d" % uid
	pivot.position = cell_to_world(Vector2(cell))
	_units_root.add_child(pivot)

	var team_color := OWN_COLOR if team == viewer_team else ENEMY_COLOR

	# Base: disco colorato per squadra, con un anello più chiaro che si accende
	# quando l'unità lancia l'abilità. È volutamente piccolo e spento: a piena
	# saturazione i due colori prendevano il sopravvento sulle figure, e la
	# scacchiera si leggeva come una fila di bolli verdi contro una di bolli rossi.
	var base := MeshInstance3D.new()
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 0.30
	base_mesh.bottom_radius = 0.30
	base_mesh.height = 0.03
	base_mesh.radial_segments = 16
	base_mesh.rings = 1
	base.mesh = base_mesh
	var base_material := StandardMaterial3D.new()
	base_material.albedo_color = team_color.darkened(0.45)
	base_material.emission_enabled = true
	base_material.emission = team_color
	base_material.emission_energy_multiplier = 0.18
	base.material_override = base_material
	base.position = Vector3(0, 0.02, 0)
	pivot.add_child(base)

	var ring := MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.36
	ring_mesh.outer_radius = 0.46
	ring_mesh.rings = 18
	ring_mesh.ring_segments = 4
	ring.mesh = ring_mesh
	var ring_material := StandardMaterial3D.new()
	ring_material.albedo_color = Color(1, 1, 1)
	ring_material.emission_enabled = true
	ring_material.emission = Color(1, 1, 1)
	ring_material.emission_energy_multiplier = 2.0
	ring.material_override = ring_material
	ring.position = Vector3(0, 0.03, 0)
	ring.visible = false
	pivot.add_child(ring)

	var model := UnitModels.build(unit_id, origin)
	# Le stelle ingrandiscono la figura: un'unità a 3★ deve pesare di più anche
	# visivamente, non solo nelle statistiche.
	# Le figure partono sopra la scala nominale: in una cella da 1.0 unità viste
	# di scorcio, a scala 1 restavano piccole rispetto alla casella.
	var star_scale := 1.18 + 0.10 * float(clampi(star, 1, 3) - 1)
	model.scale = Vector3.ONE * star_scale
	# La squadra vicina alla camera guarda verso il campo avversario.
	model.rotation_degrees = Vector3(0, 180.0 if team == viewer_team else 0.0, 0)
	pivot.add_child(model)

	# Marcatori di stella: piccoli prismi dorati che orbitano sopra la testa.
	var height := UnitModels.height_of(unit_id) * star_scale
	if star > 1:
		var stars := Node3D.new()
		stars.position = Vector3(0, height + 0.08, 0)
		pivot.add_child(stars)
		for i in star:
			var pip := MeshInstance3D.new()
			var pip_mesh := PrismMesh.new()
			pip_mesh.size = Vector3(0.07, 0.07, 0.02)
			pip.mesh = pip_mesh
			var pip_material := StandardMaterial3D.new()
			pip_material.albedo_color = Color(1.0, 0.84, 0.35)
			pip_material.emission_enabled = true
			pip_material.emission = Color(1.0, 0.80, 0.30)
			pip_material.emission_energy_multiplier = 1.2
			pip.material_override = pip_material
			pip.position = Vector3((float(i) - float(star - 1) * 0.5) * 0.09, 0, 0)
			stars.add_child(pip)

	_units[uid] = {
		"pivot": pivot,
		"model": model,
		"base": base,
		"ring": ring,
		"height": height,
		"base_scale": star_scale,
	}


## Aggiorna la resa di un'unità in un fotogramma.
##
## `punch` è l'intensità del sussulto da colpo (0..1), `collapse` l'avanzamento
## della morte (0..1). La morte non usa la trasparenza ma un affondamento con
## rimpicciolimento: i materiali sono condivisi fra tutte le istanze e renderli
## trasparenti uno per uno costerebbe una copia di materiale per unità, oltre a
## rendere l'ordine di disegno instabile.
func update_unit(uid: int, cell: Vector2, punch: float, casting: bool, collapse: float) -> void:
	var entry: Dictionary = _units.get(uid, {})
	if entry.is_empty():
		return
	var pivot: Node3D = entry["pivot"]
	var model: Node3D = entry["model"]
	var base_scale: float = float(entry["base_scale"])

	var ground := cell_to_world(cell)
	# Il sussulto solleva appena l'unità: dall'alto uno spostamento verticale si
	# legge meglio di uno orizzontale.
	pivot.position = ground + Vector3(0, punch * 0.06 - collapse * 0.35, 0)

	var scale_factor := base_scale * (1.0 + punch * 0.10) * (1.0 - collapse * 0.65)
	model.scale = Vector3.ONE * maxf(scale_factor, 0.01)
	entry["base"].visible = collapse <= 0.0

	var ring: MeshInstance3D = entry["ring"]
	ring.visible = casting
	if casting:
		# L'anello pulsa mentre l'abilità parte.
		var pulse := 1.0 + 0.25 * sin(Time.get_ticks_msec() * 0.02)
		ring.scale = Vector3(pulse, 1.0, pulse)


## Fa guardare l'unità verso un'altra: rende leggibile chi sta attaccando chi
## senza bisogno di frecce.
func face_unit(uid: int, target_uid: int) -> void:
	var entry: Dictionary = _units.get(uid, {})
	var target: Dictionary = _units.get(target_uid, {})
	if entry.is_empty() or target.is_empty():
		return
	var from: Node3D = entry["pivot"]
	var to: Node3D = target["pivot"]
	var delta := to.position - from.position
	if delta.length_squared() < 0.0001:
		return
	var model: Node3D = entry["model"]
	# Il modello guarda verso +Z nella posa base, quindi l'imbardata è
	# l'angolo del vettore sul piano.
	model.rotation_degrees.y = rad_to_deg(atan2(delta.x, delta.z))


func has_unit(uid: int) -> bool:
	return _units.has(uid)


func set_unit_visible(uid: int, value: bool) -> void:
	var entry: Dictionary = _units.get(uid, {})
	if not entry.is_empty():
		entry["pivot"].visible = value


## Da richiamare quando il viewport cambia dimensione, perché l'inquadratura
## ortogonale dipende dalle proporzioni.
func on_viewport_resized() -> void:
	_place_camera()
