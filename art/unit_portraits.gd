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
## Ogni voce è {"id": String, "kind": "unit"|"hero"}.
var _queue: Array[Dictionary] = []
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
	return _texture_for_impl(unit_id, "unit")


## Ritratto dell'eroe, stessa logica asincrona di texture_for().
func hero_texture_for(hero_id: String) -> Texture2D:
	return _texture_for_impl(hero_id, "hero")


func _texture_for_impl(id: String, kind: String) -> Texture2D:
	var key := "%s:%s" % [kind, id]
	if _textures.has(key):
		return _textures[key]
	if is_available() and not _queued.has(key):
		_queued[key] = true
		_queue.append({"id": id, "kind": kind})
		_process_queue()
	return null


## Genera in anticipo un gruppo di ritratti, così non compaiono a scoppio
## ritardato mentre si gioca.
func preload_units(unit_ids: Array) -> void:
	for unit_id in unit_ids:
		texture_for(String(unit_id))


func preload_heroes(hero_ids: Array) -> void:
	for hero_id in hero_ids:
		hero_texture_for(String(hero_id))


func has_portrait(unit_id: String) -> bool:
	return _textures.has("unit:%s" % unit_id)


func has_hero_portrait(hero_id: String) -> bool:
	return _textures.has("hero:%s" % hero_id)


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

	var rendering: Array[Dictionary] = []
	while not _queue.is_empty() and rendering.size() < _stations.size():
		var entry: Dictionary = _queue.pop_front()
		var key := "%s:%s" % [entry["kind"], entry["id"]]
		var model: Node3D = null
		var height := 1.0
		if entry["kind"] == "hero":
			if not GameData.has_hero(entry["id"]):
				_queued.erase(key)
				continue
			model = UnitModels.build_hero(entry["id"])
			height = UnitModels.height_of_hero(entry["id"])
		else:
			if not GameData.has_unit(entry["id"]):
				_queued.erase(key)
				continue
			var def := GameData.unit(entry["id"])
			model = UnitModels.build(entry["id"], def.origin)
			height = UnitModels.height_of(entry["id"])
		_prepare_station(_stations[rendering.size()], model, height)
		rendering.append(entry)

	if rendering.is_empty():
		_busy = false
		return

	await RenderingServer.frame_post_draw

	for i in rendering.size():
		var entry: Dictionary = rendering[i]
		var key := "%s:%s" % [entry["kind"], entry["id"]]
		var viewport: SubViewport = _stations[i]["viewport"]
		var image := viewport.get_texture().get_image()
		if image != null and not image.is_empty():
			_textures[key] = ImageTexture.create_from_image(image)
			portrait_ready.emit(entry["id"])
		_queued.erase(key)

	_busy = false
	_process_queue()


func _prepare_station(station: Dictionary, model: Node3D, height: float) -> void:
	var model_root: Node3D = station["model_root"]
	for child in model_root.get_children():
		model_root.remove_child(child)
		child.queue_free()
	model_root.add_child(model)

	# La camera guarda il centro della figura, non i piedi: le unità basse
	# (le macchine d'assedio) resterebbero altrimenti nella metà inferiore.
	# Il centro sta sopra la metà: elmi, creste e archi sporgono verso l'alto,
	# mentre sotto i piedi non c'è nulla da inquadrare.
	var centre := Vector3(0, height * 0.58, 0)
	var camera: Camera3D = station["camera"]
	camera.size = height * ZOOM
	camera.position = centre + CAMERA_OFFSET
	camera.look_at(centre, Vector3.UP)

	station["viewport"].render_target_update_mode = SubViewport.UPDATE_ONCE
