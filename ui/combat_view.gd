class_name CombatView
extends Control

## Riproduce una battaglia già risolta.
##
## Non simula nulla: legge lo schieramento iniziale e il log di eventi
## prodotti da CombatSim e li rigioca sull'orologio. È la ragione per cui il
## risolutore produce un log invece di limitarsi a restituire un vincitore —
## la stessa registrazione servirà per i replay e per il multiplayer, dove il
## client riceve gli eventi e non conosce lo stato del server.
##
## La messa in scena è 3D vista dall'alto (BattleBoard3D dentro un SubViewport),
## ma barre della salute, numeri di danno e orologio restano disegnati con
## l'API 2D dei Control sopra l'immagine: il testo resta nitido a ogni
## risoluzione e non costa né mesh né materiali. Le posizioni dei due mondi si
## incontrano in un solo punto, `BattleBoard3D.project()`.

signal playback_finished

## Dimensione di riferimento del riquadro nell'interfaccia. Non è più la
## dimensione delle celle — quella la decide la camera 3D — ma serve al layout
## per riservare uno spazio con le proporzioni giuste.
const CELL := Vector2(94, 74)
const CELL_GAP := 4.0
const MOVE_DURATION := 0.22
const HIT_DURATION := 0.18
const FLOATER_DURATION := 0.9
const DEATH_FADE := 0.45
const CAST_FLASH := 0.35

## Verde per la propria squadra, rosso per l'avversaria: l'assegnazione dipende
## da chi guarda, non dal numero della squadra.
const OWN_COLOR := Color(0.4, 0.8, 0.45)
const ENEMY_COLOR := Color(0.92, 0.42, 0.38)
const ORIGIN_MARKS := {"roman": "R", "gaul": "G", "teuton": "T"}

const BAR_SIZE := Vector2(58.0, 8.0)

var speed: float = 1.0
var is_playing: bool = false

## Squadra di chi guarda: viene sempre disegnata nella metà vicina alla camera,
## come nella schermata di preparazione. Senza questo, metà delle battaglie
## apparirebbe capovolta.
var viewer_team: int = 0

var _columns: int = 7
var _rows: int = 8
var _flip: bool = false
var _duration: float = 0.0
var _events: Array = []
var _event_index: int = 0
var _time: float = 0.0

## uid -> stato visivo dell'unità
var _units: Dictionary = {}
## Testi che salgono sopra le unità colpite: {world, text, color, born}
var _floaters: Array[Dictionary] = []
## Linee d'attacco disegnate per un istante: {from_uid, to_uid, color, born}
var _flashes: Array[Dictionary] = []

var _font: Font
var _board: BattleBoard3D
var _viewport: SubViewport


func _ready() -> void:
	_font = ThemeDB.fallback_font
	custom_minimum_size = Vector2(
		_columns * (CELL.x + CELL_GAP),
		_rows * (CELL.y + CELL_GAP) + 28.0
	)
	_build_scene()
	set_process(false)


## Il 3D vive in un SubViewport invece che nell'albero principale: la finestra
## di gioco resta un'interfaccia 2D (stretch canvas_items, menu, negozio) e la
## battaglia è un riquadro dentro quel layout, non una scena che se lo mangia.
func _build_scene() -> void:
	var container := SubViewportContainer.new()
	container.stretch = true
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Un Control disegna se stesso prima dei propri figli, quindi il _draw di
	# CombatView finirebbe sotto l'immagine della battaglia. Mandare il riquadro
	# 3D dietro al genitore rimette la sovrimpressione al suo posto senza
	# doverla spostare in un nodo separato.
	container.show_behind_parent = true
	add_child(container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_viewport)

	_board = BattleBoard3D.new()
	_viewport.add_child(_board)

	resized.connect(_on_resized)


func _on_resized() -> void:
	if _board != null:
		_board.on_viewport_resized()


## Carica una battaglia risolta e si prepara a riprodurla dall'inizio.
## `team` è la squadra dello spettatore, che verrà mostrata nella metà vicina.
func load_combat(combat: Dictionary, team: int = 0) -> void:
	viewer_team = team
	# Il risolutore mette sempre la squadra 0 in alto: se lo spettatore è
	# quella, la vista va capovolta.
	_flip = team == 0
	_columns = int(combat.get("columns", 7))
	_rows = int(combat.get("rows", 8))
	_duration = float(combat.get("duration", 0.0))
	_events = combat.get("events", [])
	_event_index = 0
	_time = 0.0
	_floaters.clear()
	_flashes.clear()

	_board.configure(_columns, _rows, _flip, viewer_team)
	_board.clear_units()

	_units.clear()
	for entry in combat.get("initial", []):
		var cell: Vector2i = entry["cell"]
		var uid := int(entry["uid"])
		_units[uid] = {
			"id": String(entry.get("id", "")),
			"name": String(entry["name"]),
			"origin": String(entry["origin"]),
			"star": int(entry["star"]),
			"team": int(entry["team"]),
			"cell": cell,
			"from_cell": Vector2(cell),
			"move_start": -1.0,
			"max_hp": float(entry["max_hp"]),
			"hp": float(entry["max_hp"]),
			"shield": float(entry.get("shield", 0.0)),
			"alive": true,
			"death_time": -1.0,
			"hit_time": -1.0,
			"cast_time": -1.0,
			"stun_until": -1.0,
			"buried": false,
		}
		_board.spawn_unit(
			uid,
			String(entry.get("id", "")),
			String(entry["origin"]),
			int(entry["team"]),
			cell,
			int(entry["star"])
		)

	custom_minimum_size = Vector2(
		_columns * (CELL.x + CELL_GAP),
		_rows * (CELL.y + CELL_GAP) + 28.0
	)
	_sync_board()
	queue_redraw()


func play() -> void:
	is_playing = true
	set_process(true)


func pause() -> void:
	is_playing = false
	set_process(false)


## Salta alla fine applicando tutti gli eventi rimasti: per chi non vuole
## guardare. Lo stato finale è identico a quello che si otterrebbe aspettando.
func skip_to_end() -> void:
	while _event_index < _events.size():
		_apply_event(_events[_event_index])
		_event_index += 1
	_time = _duration
	_sync_board()
	_finish()


func _process(delta: float) -> void:
	_time += delta * speed

	while _event_index < _events.size() and float(_events[_event_index]["t"]) <= _time:
		_apply_event(_events[_event_index])
		_event_index += 1

	_expire_effects()
	_sync_board()
	queue_redraw()

	# La riproduzione finisce quando gli eventi sono esauriti e le animazioni
	# in corso hanno avuto il tempo di concludersi.
	if _event_index >= _events.size() and _time >= _duration:
		_finish()


func _finish() -> void:
	if not is_playing and not is_processing():
		return
	is_playing = false
	set_process(false)
	_floaters.clear()
	_flashes.clear()
	queue_redraw()
	playback_finished.emit()


func _expire_effects() -> void:
	_floaters = _floaters.filter(func(f): return _time - float(f["born"]) < FLOATER_DURATION)
	_flashes = _flashes.filter(func(f): return _time - float(f["born"]) < HIT_DURATION)


# --------------------------------------------------------------------------
# Applicazione degli eventi
# --------------------------------------------------------------------------

func _apply_event(event: Dictionary) -> void:
	var type := String(event["type"])
	match type:
		"move":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if unit.is_empty():
				return
			# La posizione visiva parte da dove l'unità si trova ORA, non dalla
			# cella d'origine: altrimenti due passi ravvicinati farebbero
			# scattare l'unità all'indietro.
			unit["from_cell"] = _current_cell(unit)
			unit["cell"] = event["to"]
			unit["move_start"] = _time

		"attack":
			var attacker: Dictionary = _units.get(int(event["uid"]), {})
			var target: Dictionary = _units.get(int(event["target"]), {})
			if attacker.is_empty() or target.is_empty():
				return
			attacker["hit_time"] = _time
			# Girare l'attaccante verso il bersaglio rende leggibile chi sta
			# colpendo chi anche quando la linea del colpo è già svanita.
			_board.face_unit(int(event["uid"]), int(event["target"]))
			_flashes.append({
				"from_uid": int(event["uid"]),
				"to_uid": int(event["target"]),
				"color": _team_color(int(attacker["team"])),
				"born": _time,
				"crit": bool(event.get("crit", false)),
			})

		"damage":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if unit.is_empty():
				return
			unit["hp"] = float(event["hp"])
			unit["shield"] = float(event.get("shield", 0.0))
			unit["hit_time"] = _time
			var amount := int(roundf(float(event["amount"])))
			if amount > 0:
				_add_floater(int(event["uid"]), "-%d" % amount, Color(1.0, 0.85, 0.4))

		"heal":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if unit.is_empty():
				return
			unit["hp"] = float(event["hp"])
			unit["shield"] = float(event.get("shield", 0.0))
			var amount := int(roundf(float(event.get("amount", 0.0))))
			if amount > 0:
				_add_floater(int(event["uid"]), "+%d" % amount, Color(0.5, 0.95, 0.55))

		"periodic":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if unit.is_empty():
				return
			unit["hp"] = float(event["hp"])

		"cast":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if unit.is_empty():
				return
			unit["cast_time"] = _time
			_add_floater(int(event["uid"]), String(event.get("name", "")), Color(0.7, 0.8, 1.0), 0.30)

		"stun":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if not unit.is_empty():
				unit["stun_until"] = _time + 1.0

		"death":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if unit.is_empty():
				return
			unit["alive"] = false
			unit["hp"] = 0.0
			unit["death_time"] = _time


## `lift` alza il testo nel mondo, non sullo schermo: così il nome di
## un'abilità compare sopra la testa dell'unità qualunque sia l'inquadratura.
func _add_floater(uid: int, text: String, color: Color, lift: float = 0.0) -> void:
	if text.is_empty():
		return
	_floaters.append({
		"world": _board.unit_overhead(uid) + Vector3(0, lift, 0),
		"text": text,
		"color": color,
		"born": _time,
	})


# --------------------------------------------------------------------------
# Sincronizzazione con la scena 3D
# --------------------------------------------------------------------------

## Cella corrente, interpolata durante uno spostamento.
func _current_cell(unit: Dictionary) -> Vector2:
	var target := Vector2(unit["cell"])
	var started := float(unit["move_start"])
	if started < 0.0:
		return target
	var progress: float = clampf((_time - started) / MOVE_DURATION, 0.0, 1.0)
	return Vector2(unit["from_cell"]).lerp(target, ease(progress, -1.8))


## Riporta sul mondo 3D lo stato di tutte le unità. È l'unico punto in cui la
## riproduzione tocca la scena: tutto il resto lavora su numeri.
func _sync_board() -> void:
	for uid in _units:
		var unit: Dictionary = _units[uid]

		var collapse := 0.0
		if not bool(unit["alive"]):
			var elapsed := _time - float(unit["death_time"])
			collapse = clampf(elapsed / DEATH_FADE, 0.0, 1.0)
			if collapse >= 1.0:
				# Una volta sprofondata, l'unità si nasconde e non viene più
				# aggiornata: restare nell'albero costerebbe disegno inutile.
				if not bool(unit["buried"]):
					unit["buried"] = true
					_board.set_unit_visible(int(uid), false)
				continue

		var punch := 0.0
		var since_hit := _time - float(unit["hit_time"])
		if since_hit >= 0.0 and since_hit < HIT_DURATION:
			punch = 1.0 - since_hit / HIT_DURATION

		var since_cast := _time - float(unit["cast_time"])
		var casting := since_cast >= 0.0 and since_cast < CAST_FLASH

		_board.update_unit(int(uid), _current_cell(unit), punch, casting, collapse)


func _team_color(team: int) -> Color:
	return OWN_COLOR if team == viewer_team else ENEMY_COLOR


# --------------------------------------------------------------------------
# Sovrimpressione 2D
# --------------------------------------------------------------------------

func _draw() -> void:
	for flash in _flashes:
		_draw_flash(flash)
	for uid in _units:
		_draw_unit_hud(int(uid), _units[uid])
	for floater in _floaters:
		_draw_floater(floater)
	_draw_clock()


## Barra della salute e stato di un'unità, ancorate sopra la sua testa nel
## mondo 3D. Il nome resta fuori: con venti unità in campo, venti etichette
## sovrapposte coprirebbero la battaglia. Restano il colore della squadra, la
## salute e i segnali di stordimento, che sono ciò che si legge in corsa.
func _draw_unit_hud(uid: int, unit: Dictionary) -> void:
	var alpha := 1.0
	if not bool(unit["alive"]):
		var elapsed := _time - float(unit["death_time"])
		if elapsed >= DEATH_FADE:
			return
		alpha = 1.0 - elapsed / DEATH_FADE

	var anchor := _board.project(_board.unit_overhead(uid))
	var bar := Rect2(anchor - Vector2(BAR_SIZE.x * 0.5, BAR_SIZE.y), BAR_SIZE)

	draw_rect(bar.grow(1.0), Color(0, 0, 0, 0.6 * alpha), true)
	var ratio: float = clampf(float(unit["hp"]) / maxf(1.0, float(unit["max_hp"])), 0.0, 1.0)
	var health_color := Color(0.45, 0.85, 0.45, alpha) if int(unit["team"]) == viewer_team else Color(0.9, 0.45, 0.42, alpha)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), health_color, true)

	# Lo scudo si sovrappone alla barra in chiaro, come nella vista precedente.
	var shield_ratio: float = clampf(float(unit["shield"]) / maxf(1.0, float(unit["max_hp"])), 0.0, 1.0)
	if shield_ratio > 0.0:
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * shield_ratio, 2.0)),
			Color(0.9, 0.9, 0.95, alpha), true)

	# Iniziale della civiltà: la palette dei modelli distingue già i tre
	# eserciti, ma con due squadre della stessa civiltà serve un'ancora certa.
	var mark: String = ORIGIN_MARKS.get(String(unit["origin"]), "?")
	draw_string(_font, bar.position + Vector2(-17.0, BAR_SIZE.y), mark,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.8, 0.8, 0.88, alpha))

	if _time < float(unit["stun_until"]) and bool(unit["alive"]):
		draw_string(_font, bar.position + Vector2(bar.size.x + 4.0, BAR_SIZE.y), "!",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 19, Color(1.0, 0.9, 0.3, alpha))


## La linea del colpo viene proiettata al momento del disegno, non salvata come
## coppia di punti: attaccante e bersaglio possono muoversi durante i pochi
## centesimi in cui resta visibile.
func _draw_flash(flash: Dictionary) -> void:
	var progress: float = (_time - float(flash["born"])) / HIT_DURATION
	var color: Color = flash["color"]
	color.a = 1.0 - progress
	var from := _board.project(_board.unit_centre(int(flash["from_uid"])))
	var to := _board.project(_board.unit_centre(int(flash["to_uid"])))
	draw_line(from, to, color, 4.5 if bool(flash["crit"]) else 2.5)


func _draw_floater(floater: Dictionary) -> void:
	var progress: float = (_time - float(floater["born"])) / FLOATER_DURATION
	var color: Color = floater["color"]
	color.a = 1.0 - progress
	var position := _board.project(floater["world"]) + Vector2(0, -38.0 * progress)
	draw_string(_font, position, String(floater["text"]),
		HORIZONTAL_ALIGNMENT_CENTER, 0, 20, color)


func _draw_clock() -> void:
	var y := size.y - 10.0
	draw_string(_font, Vector2(6, y), "%.1fs / %.1fs   ×%.0f" % [minf(_time, _duration), _duration, speed],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.72, 0.72, 0.80))
