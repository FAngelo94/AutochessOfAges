extends Node

## Ritratti delle unità: gli stessi modelli 3D della battaglia, renderizzati
## una volta sola in una texture riusabile ovunque nell'interfaccia 2D.
## Registrato come autoload "Portraits".
##
## L'alternativa — un SubViewport 3D vivo dentro ogni casella — costerebbe una
## quarantina di viewport sempre attivi per mostrare figure immobili. Qui
## invece si rende una volta sola per sessione: venti texture in tutto,
## condivise da negozio, griglia, panchina e collezione.
##
## Le figure si rendono a gruppi, non una per fotogramma: un viewport produce
## una sola immagine per fotogramma, quindi ne servono diversi in parallelo.
## Con un solo viewport l'intero elenco impiegava venti fotogrammi a comparire,
## abbastanza perché aprendo subito la collezione si trovassero caselle ancora
## col nome scritto.
##
## Su un server senza schermo (i test headless) non si renderizza nulla: chi
## chiede un ritratto riceve null e mostra il proprio ripiego testuale.

## Emesso quando un ritratto è pronto. Chi lo aspetta si ridisegna.
signal portrait_ready(unit_id: String)

const SIZE := 192

## Inquadratura di tre quarti dall'alto: mostra insieme la sagoma vista da
## sopra — quella che si riconosce in battaglia — e il profilo, che dà volume.
## Una vista puramente dall'alto renderebbe ogni fante un disco.
const CAMERA_OFFSET := Vector3(1.15, 1.35, 2.05)

## L'inquadratura si adatta all'altezza della figura invece di essere fissa:
## con una sola misura o i cavalieri uscivano dal riquadro, o i fanti ci
## nuotavano dentro. Il fattore lascia il margine per armi e scudi, che
## sporgono di lato più di quanto la figura sia alta.
const ZOOM := 1.85

## Quante figure si rendono nello stesso fotogramma.
const BATCH := 8

var _textures: Dictionary = {}
var _queue: Array[String] = []
var _queued: Dictionary = {}
## Postazioni di rendering: {viewport, camera, model_root}, una per figura del
## gruppo in corso.
var _stations: Array[Dictionary] = []
var _busy := false


func _ready() -> void:
	if not is_available():
		return
	for i in BATCH:
		_stations.append(_build_station())


## Falso quando non c'è un rendering utilizzabile (esecuzioni headless): in quel
## caso i ritratti non arrivano mai e l'interfaccia resta sul testo.
func is_available() -> bool:
	return DisplayServer.get_name() != "headless"


## Ritratto dell'unità, o null se non è ancora pronto. La prima chiamata mette
## in coda la generazione; quando finisce arriva portrait_ready.
func texture_for(unit_id: String) -> Texture2D:
	if _textures.has(unit_id):
		return _textures[unit_id]
	if is_available() and not _queued.has(unit_id):
		_queued[unit_id] = true
		_queue.append(unit_id)
		_process_queue()
	return null


## Genera in anticipo un gruppo di ritratti, così non compaiono a scoppio
## ritardato mentre si gioca.
func preload_units(unit_ids: Array) -> void:
	for unit_id in unit_ids:
		texture_for(String(unit_id))


func has_portrait(unit_id: String) -> bool:
	return _textures.has(unit_id)


## Vero quando non resta nulla in coda. Serve agli strumenti che catturano
## schermate: senza aspettare, fotograferebbero caselle ancora senza figura.
func is_idle() -> bool:
	return _queue.is_empty() and not _busy


# --------------------------------------------------------------------------

## Una postazione di rendering completa: viewport, luci, camera e un posto
## dove appendere il modello.
func _build_station() -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(SIZE, SIZE)
	# Sfondo trasparente: il ritratto si posa sul colore della casella, che
	# cambia con la rarità e con la selezione.
	viewport.transparent_bg = true
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.msaa_3d = Viewport.MSAA_4X
	add_child(viewport)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.58, 0.62, 0.72)
	environment.ambient_light_energy = 0.9

	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	viewport.add_child(world_environment)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, 34, 0)
	key.light_energy = 1.25
	key.light_color = Color(1.0, 0.96, 0.9)
	viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-16, -145, 0)
	fill.light_energy = 0.5
	fill.light_color = Color(0.68, 0.76, 1.0)
	viewport.add_child(fill)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.05
	camera.far = 20.0
	viewport.add_child(camera)

	var model_root := Node3D.new()
	viewport.add_child(model_root)

	return {"viewport": viewport, "camera": camera, "model_root": model_root}


## Un gruppo di figure per fotogramma.
func _process_queue() -> void:
	if _busy or _queue.is_empty() or _stations.is_empty():
		return
	_busy = true
	_render_batch.call_deferred()


func _render_batch() -> void:
	if _queue.is_empty():
		_busy = false
		return

	var rendering: Array[String] = []
	while not _queue.is_empty() and rendering.size() < _stations.size():
		var unit_id: String = _queue.pop_front()
		var def := GameData.unit(unit_id)
		if def == null:
			_queued.erase(unit_id)
			continue
		_prepare_station(_stations[rendering.size()], unit_id, def.origin)
		rendering.append(unit_id)

	if rendering.is_empty():
		_busy = false
		return

	await RenderingServer.frame_post_draw

	for i in rendering.size():
		var unit_id: String = rendering[i]
		var viewport: SubViewport = _stations[i]["viewport"]
		var image := viewport.get_texture().get_image()
		if image != null and not image.is_empty():
			_textures[unit_id] = ImageTexture.create_from_image(image)
			portrait_ready.emit(unit_id)
		_queued.erase(unit_id)

	_busy = false
	_process_queue()


func _prepare_station(station: Dictionary, unit_id: String, origin: String) -> void:
	var model_root: Node3D = station["model_root"]
	for child in model_root.get_children():
		model_root.remove_child(child)
		child.queue_free()
	model_root.add_child(UnitModels.build(unit_id, origin))

	# La camera guarda il centro della figura, non i piedi: le unità basse
	# (le macchine d'assedio) resterebbero altrimenti nella metà inferiore.
	var height := UnitModels.height_of(unit_id)
	# Il centro sta sopra la metà: elmi, creste e archi sporgono verso l'alto,
	# mentre sotto i piedi non c'è nulla da inquadrare.
	var centre := Vector3(0, height * 0.58, 0)
	var camera: Camera3D = station["camera"]
	camera.size = height * ZOOM
	camera.position = centre + CAMERA_OFFSET
	camera.look_at(centre, Vector3.UP)

	station["viewport"].render_target_update_mode = SubViewport.UPDATE_ONCE
