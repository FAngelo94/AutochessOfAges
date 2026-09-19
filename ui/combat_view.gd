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

## Annuncio del berserk: compare quando la simulazione passa a velocità tripla e
## si dissolve nell'arco di BERSERK_BANNER_FADE secondi. La durata è quella
## chiesta a schermo, non ha rapporto con la finestra accelerata, che è più lunga.
const BERSERK_BANNER_FADE := 3.0
const BERSERK_COLOR := Color(0.98, 0.36, 0.28)

## Verde per la propria squadra, rosso per l'avversaria: l'assegnazione dipende
## da chi guarda, non dal numero della squadra.
const OWN_COLOR := Color(0.4, 0.8, 0.45)
const ENEMY_COLOR := Color(0.92, 0.42, 0.38)

const BAR_SIZE := Vector2(58.0, 8.0)
const MANA_BAR_HEIGHT := 4.0

## Salva di frecce di fine round tra i ritratti eroe. Volutamente diversa dalle
## linee di colpo tra unità (_draw_flash: un filo dritto che sbiadisce): dal
## vincitore parte una raffica di frecce ad arco, sfalsate e con un po' di
## dispersione, che si conficcano nel ritratto dello sconfitto. Più vita si perde,
## più frecce partono. Tutto è scandito su _result_time.
const RESULT_VOLLEY_DURATION := 1.0
const RESULT_VOLLEY_MIN_ARROWS := 3
const RESULT_VOLLEY_MAX_ARROWS := 12
const RESULT_VOLLEY_FLIGHT := 0.42    # secondi di volo di una freccia
const RESULT_VOLLEY_STAGGER := 0.32   # finestra in cui partono tutte
const RESULT_VOLLEY_IMPACT := 0.18    # durata dell'anello d'impatto
const RESULT_ARROW_LENGTH := 30.0
const RESULT_ARROW_SCALE := 1.5       # fattore su lunghezza e spessori: sul telefono 30 px sono troppo pochi

## Fasce riservate agli eroi sopra e sotto la scacchiera 3D: senza queste, il
## riquadro 3D copriva l'intero controllo e i ritratti agli angoli finivano
## sovrapposti alle celle estreme del campo. Restringendo il SubViewport a
## un'area centrale, queste fasce restano libere per i piedistalli degli eroi
## e per lo sfondo da arena, e non fanno mai parte della simulazione 3D.
## Sfondo dell'arena: un'immagine 2D disegnata sotto tutto il resto — griglia
## 3D, unità e sovrimpressione. Sta fuori dal mondo 3D di proposito: è una
## quinta, non una superficie di gioco, e come Control segue il riquadro senza
## dipendere da camera, luci o proiezione.
const ARENA_BACKGROUND := "res://art/backgrounds/battle_arena.png"

const HERO_ZONE_TOP := 10.0
const HERO_ZONE_BOTTOM := 72.0
const HERO_PORTRAIT_SIZE := 56.0

## Gli angoli sono fissi (vedi sotto): l'avversario sta sempre in alto a
## sinistra e il giocatore sempre in basso a destra, quindi ognuno guarda
## sempre verso l'angolo opposto — una leggera rotazione, non un dietro-front.
const HERO_TURN_DEGREES := 20.0

var speed: float = 1.0
var is_playing: bool = false
## true mentre la salva di fine round sta animando: _process() in questo
## stato non tocca gli eventi di riproduzione, che sono già tutti esauriti.
var _result_animating: bool = false

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

## Salva finale tra i due ritratti eroe a fine round, e il numero di
## vita persa che sale sopra il ritratto sconfitto. Sono in coordinate
## schermo, non del mondo 3D: i ritratti sono agganciati agli angoli
## dell'interfaccia, non a un'unità in campo, quindi non possono usare
## _floaters/_flashes che proiettano da BattleBoard3D.
var _hero_volley: Dictionary = {}
var _hero_floater: Dictionary = {}
## Istante di riproduzione in cui il berserk è stato annunciato. < 0 = non
## ancora, ed è la simulazione a dirlo con un evento: la vista non conosce la
## soglia e non la ricalcola.
var _berserk_time: float = -1.0
## Orologio dedicato all'animazione di fine round: separato da _time, che
## smette di avanzare quando la riproduzione finisce.
var _result_time: float = 0.0
## Istante dell'ultima morte applicata. La battaglia finisce quasi sempre nello
## stesso istante in cui muore l'ultima unità di una squadra, quindi senza
## questo _finish() scattava a `_duration` prima che la sua dissolvenza
## (DEATH_FADE) avesse il tempo di giocare: l'unità restava impagliata a piena
## vita sull'ultimo fotogramma invece di sprofondare.
var _last_death_time: float = -1.0

var _font: Font
var _board: BattleBoard3D
var _viewport: SubViewport
var _backdrop: TextureRect
var _self_hero_portrait: TextureRect
var _opponent_hero_portrait: TextureRect
var _self_hero_id: String = ""
var _opponent_hero_id: String = ""


func _ready() -> void:
	_font = ThemeDB.fallback_font
	custom_minimum_size = _board_pixel_size()
	_build_scene()
	set_process(false)
	if get_node("/root/Portraits").is_available():
		get_node("/root/Portraits").portrait_ready.connect(_on_hero_portrait_ready)


## Il 3D vive in un SubViewport invece che nell'albero principale: la finestra
## di gioco resta un'interfaccia 2D (stretch canvas_items, menu, negozio) e la
## battaglia è un riquadro dentro quel layout, non una scena che se lo mangia.
func _build_scene() -> void:
	# Aggiunto prima del riquadro 3D: fra fratelli entrambi `show_behind_parent`
	# l'ordine di disegno resta quello dell'albero, quindi lo sfondo finisce
	# sotto la scacchiera e le unità.
	# L'arena si vede PER INTERO dentro la fascia di battaglia: KEEP_ASPECT (non
	# COVERED) non ritaglia nulla, e il rapporto dell'arte (2:3) è quasi identico
	# a quello del riquadro, quindi le bande di crepuscolo ai lati sono minime.
	# L'accampamento romano resta sopra la griglia, quello barbaro sotto.
	_backdrop = TextureRect.new()
	# EXPAND_IGNORE_SIZE: senza questo il TextureRect tiene come dimensione minima
	# quella della texture (1024×1536) e le ancore FULL_RECT non riescono a
	# rimpicciolirlo — restava grande quanto l'immagine e se ne vedeva solo la
	# parte alta. Così invece obbedisce al riquadro e KEEP_ASPECT vi fa entrare
	# l'arena PER INTERO (romani sopra, barbari sotto), con bande minime ai lati.
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.show_behind_parent = true
	if ResourceLoader.exists(ARENA_BACKGROUND):
		_backdrop.texture = load(ARENA_BACKGROUND)
	add_child(_backdrop)

	var container := SubViewportContainer.new()
	container.stretch = true
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Il riquadro 3D resta rientrato di HERO_ZONE_TOP/BOTTOM rispetto al
	# controllo: le due fasce libere che ne risultano sopra e sotto ospitano i
	# ritratti degli eroi e lo sfondo da arena, senza che nulla della scena 3D
	# possa mai finire disegnato sotto di loro.
	container.offset_top = HERO_ZONE_TOP
	container.offset_bottom = -HERO_ZONE_BOTTOM
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Un Control disegna se stesso prima dei propri figli, quindi il _draw di
	# CombatView finirebbe sotto l'immagine della battaglia. Mandare il riquadro
	# 3D dietro al genitore rimette la sovrimpressione al suo posto senza
	# doverla spostare in un nodo separato.
	container.show_behind_parent = true
	add_child(container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	# Il 3D è reso su fondo trasparente perché sotto ci sia l'immagine
	# dell'arena (l'Environment di BattleBoard3D ha il colore ad alpha 0).
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_viewport)

	_board = BattleBoard3D.new()
	_viewport.add_child(_board)

	# Angoli fissi in coordinate schermo: avversario in alto a sinistra,
	# giocatore in basso a destra. Indipendenti da _flip/viewer_team, che
	# riguardano solo l'orientamento della board 3D, non la UI 2D sopra di essa.
	_opponent_hero_portrait = _corner_hero_portrait()
	add_child(_opponent_hero_portrait)
	_self_hero_portrait = _corner_hero_portrait()
	add_child(_self_hero_portrait)
	_position_corner_portraits()

	resized.connect(_on_resized)


## Dimensione della board in pixel, la stessa formula usata per
## custom_minimum_size.
func _board_pixel_size() -> Vector2:
	return Vector2(
		_columns * (CELL.x + CELL_GAP),
		_rows * (CELL.y + CELL_GAP) + 28.0 + HERO_ZONE_TOP + HERO_ZONE_BOTTOM
	)


func _corner_hero_portrait() -> TextureRect:
	var rect := TextureRect.new()
	rect.custom_minimum_size = Vector2(56, 56)
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


## Entrambi i ritratti restano ancorati in alto a sinistra (anchor 0,0,0,0) e
## si posizionano con offset assoluti calcolati dalla dimensione reale del
## controllo: CombatView si allunga con SIZE_EXPAND_FILL per riempire lo
## spazio verticale e orizzontale che avanza nel layout, e il riquadro 3D
## (PRESET_FULL_RECT) si allarga insieme a lui, quindi la board disegnata
## occupa sempre l'intero controllo, non la sua sola dimensione minima.
## Usare `_board_pixel_size()` qui — fissa, calcolata solo da righe/colonne —
## ancorava i ritratti alla dimensione di default: al primo ridimensionamento
## della finestra la board visibile cresceva ma i ritratti restavano fermi.
func _position_corner_portraits() -> void:
	var board := size
	# Entrambi restano nelle fasce riservate (HERO_ZONE_TOP/BOTTOM), fuori
	# dall'area occupata dal riquadro 3D: non coprono più il campo.
	_opponent_hero_portrait.position = Vector2(-40, -40)
	_opponent_hero_portrait.size = Vector2(HERO_PORTRAIT_SIZE, HERO_PORTRAIT_SIZE)
	_self_hero_portrait.position = Vector2(board.x - 160, board.y - 230)
	_self_hero_portrait.size = Vector2(HERO_PORTRAIT_SIZE, HERO_PORTRAIT_SIZE)


## Ritratti degli eroi ai due angoli. `self_hero_id`/`opponent_hero_id` sono
## metadati del Player, non della simulazione: CombatSim/MatchState non sanno
## nulla di eroi, quindi chi chiama load_combat() passa qui i due id a parte.
func set_hero_portraits(self_hero_id: String, opponent_hero_id: String) -> void:
	_self_hero_id = self_hero_id
	_opponent_hero_id = opponent_hero_id
	var portraits := get_node("/root/Portraits")
	_self_hero_portrait.texture = portraits.hero_texture_for(self_hero_id, -HERO_TURN_DEGREES) if self_hero_id != "" else null
	_opponent_hero_portrait.texture = portraits.hero_texture_for(opponent_hero_id, HERO_TURN_DEGREES) if opponent_hero_id != "" else null


## Chiamato da ui/main.gd a battaglia conclusa (mai da _finish() stesso, per
## restare fuori dalla vista di spettatore che non riproduce mai una
## battaglia dal vivo): una salva di frecce tra i due ritratti eroe, dal
## vincitore verso lo sconfitto, con il numero di vita realmente persa in
## questo round — lo stesso valore già raccontato in _combat_outcome. Il numero
## di frecce cresce con quella vita.
func show_result_volley(winner_is_viewer: bool, damage: int) -> void:
	var source := _self_hero_portrait if winner_is_viewer else _opponent_hero_portrait
	var target := _opponent_hero_portrait if winner_is_viewer else _self_hero_portrait

	_result_time = 0.0
	# Il seme va impostato prima di costruire le frecce: _volley_noise lo legge.
	_hero_volley = {
		"active": true,
		"color": OWN_COLOR if winner_is_viewer else ENEMY_COLOR,
		"seed": randi(),
	}
	_hero_volley["arrows"] = _build_volley(
		source.position + source.size * 0.5,
		target.position + target.size * 0.5,
		target.size, damage)
	_hero_floater = {} if damage <= 0 else {
		"text": "-%d" % damage,
		"at": target.position + Vector2(target.size.x * 0.5, 0.0),
	}

	_result_animating = true
	_play_sfx("round_end")
	set_process(true)
	queue_redraw()


func _on_hero_portrait_ready(hero_id: String) -> void:
	var portraits := get_node("/root/Portraits")
	if hero_id == _self_hero_id:
		var self_texture: Texture2D = portraits.hero_texture_for(hero_id, HERO_TURN_DEGREES)
		if self_texture != null:
			_self_hero_portrait.texture = self_texture
	if hero_id == _opponent_hero_id:
		var opponent_texture: Texture2D = portraits.hero_texture_for(hero_id, HERO_TURN_DEGREES)
		if opponent_texture != null:
			_opponent_hero_portrait.texture = opponent_texture


func _on_resized() -> void:
	if _board != null:
		_board.on_viewport_resized()
	_position_corner_portraits()


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
	# Un round nuovo azzera anche l'eventuale salva del round precedente:
	# senza questo, saltare subito al round successivo lascerebbe delle frecce
	# animate a metà sopra la battaglia appena iniziata.
	_result_animating = false
	_hero_volley = {}
	_hero_floater = {}
	_berserk_time = -1.0
	_last_death_time = -1.0

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
			"mana": float(entry.get("mana", 0.0)),
			"mana_max": float(entry.get("mana_max", 0.0)),
			"has_ability": bool(entry.get("has_ability", false)),
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
			int(entry["star"]),
			float(entry.get("model_scale", 1.0))
		)

	custom_minimum_size = _board_pixel_size()
	_position_corner_portraits()
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
		_apply_event(_events[_event_index], false)
		_event_index += 1
	_time = _duration
	_sync_board()
	_finish()


func _process(delta: float) -> void:
	# L'animazione della salva di fine round riusa set_process() a riproduzione
	# già ferma, ma non deve far ripartire la lettura degli eventi né
	# richiamare _finish() una seconda volta: ha il suo orologio e la sua
	# uscita.
	if _result_animating:
		_result_time += delta
		if _result_time >= RESULT_VOLLEY_DURATION:
			_result_animating = false
			_hero_volley = {}
			_hero_floater = {}
			set_process(false)
		queue_redraw()
		return

	_time += delta * speed

	while _event_index < _events.size() and float(_events[_event_index]["t"]) <= _time:
		_apply_event(_events[_event_index], true)
		_event_index += 1

	_expire_effects()
	_sync_board()
	queue_redraw()

	# La riproduzione finisce quando gli eventi sono esauriti e le animazioni
	# in corso hanno avuto il tempo di concludersi — dissolvenza dell'ultima
	# unità morta compresa, che altrimenti scompare di scatto invece di
	# sprofondare quando la morte coincide con la fine del round.
	if _event_index >= _events.size() and _time >= _duration and _time >= _last_death_time + DEATH_FADE:
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

## `live` è vero solo quando l'evento arriva sull'orologio in _process: da
## skip_to_end() vengono applicati centinaia di eventi in un frame e non devono
## produrre suono.
func _apply_event(event: Dictionary, live: bool) -> void:
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
			attacker["mana"] = float(event.get("mana", attacker["mana"]))
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
			# Colpo inferto: solo le proprie unità, per non raddoppiare col
			# suono di "colpo ricevuto" del ramo damage.
			if live and int(attacker["team"]) == viewer_team:
				_play_sfx("hit_crit" if bool(event.get("crit", false)) else "hit")

		"damage":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if unit.is_empty():
				return
			unit["hp"] = float(event["hp"])
			unit["shield"] = float(event.get("shield", 0.0))
			unit["mana"] = float(event.get("mana", unit["mana"]))
			unit["hit_time"] = _time
			var amount := int(roundf(float(event["amount"])))
			if amount > 0:
				_add_floater(int(event["uid"]), "-%d" % amount, Color(1.0, 0.85, 0.4))
				if live and int(unit["team"]) == viewer_team:
					_play_sfx("hurt")

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
			unit["mana"] = float(event.get("mana", unit["mana"]))

		"shield":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if not unit.is_empty():
				unit["shield"] = float(event["shield"])

		"cast":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if unit.is_empty():
				return
			unit["cast_time"] = _time
			unit["mana"] = float(event.get("mana", 0.0))
			_add_floater(int(event["uid"]), String(event.get("name", "")), Color(0.7, 0.8, 1.0), 0.30)
			if live:
				_play_sfx("cast")

		"stun":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if not unit.is_empty():
				unit["stun_until"] = _time + 1.0

		"berserk":
			# Da qui in poi gli eventi sono marcati su un tempo di round che
			# scorre più lento della simulazione: si addensano, e la battaglia
			# si vede accelerare senza che la vista cambi nulla.
			_berserk_time = _time
			if live:
				_play_sfx("berserk")

		"death":
			var unit: Dictionary = _units.get(int(event["uid"]), {})
			if unit.is_empty():
				return
			unit["alive"] = false
			unit["hp"] = 0.0
			unit["death_time"] = _time
			_last_death_time = _time
			if live:
				_play_sfx("death_own" if int(unit["team"]) == viewer_team else "death_enemy")


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


func _play_sfx(clip: String) -> void:
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null:
		sfx.play(clip)


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
	_draw_berserk_banner()
	if _result_animating:
		_draw_hero_volley()
		_draw_hero_floater()


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

	# Lo scudo copre la salute a tutta altezza, a partire dalla sua estremità
	# verso sinistra: si legge come "questa parte di vita è protetta" e si
	# accorcia man mano che assorbe colpi. Se supera la salute residua sborda
	# nella parte vuota invece di sparire.
	var shield_ratio: float = clampf(float(unit["shield"]) / maxf(1.0, float(unit["max_hp"])), 0.0, 1.0)
	if shield_ratio > 0.0:
		var shield_width := bar.size.x * shield_ratio
		var shield_end := maxf(bar.size.x * ratio, shield_width)
		draw_rect(Rect2(bar.position + Vector2(shield_end - shield_width, 0.0), Vector2(shield_width, bar.size.y)),
			Color(0.95, 0.95, 1.0, 0.9 * alpha), true)

	# Mana sotto la salute: dice quanto manca all'abilità. Solo per chi ne ha
	# una, altrimenti una barra che si riempie senza mai scattare confonde.
	if bool(unit["has_ability"]) and float(unit["mana_max"]) > 0.0:
		var mana_bar := Rect2(bar.position + Vector2(0.0, bar.size.y + 2.0), Vector2(bar.size.x, MANA_BAR_HEIGHT))
		draw_rect(mana_bar.grow(1.0), Color(0, 0, 0, 0.6 * alpha), true)
		var mana_ratio: float = clampf(float(unit["mana"]) / float(unit["mana_max"]), 0.0, 1.0)
		draw_rect(Rect2(mana_bar.position, Vector2(mana_bar.size.x * mana_ratio, mana_bar.size.y)),
			Color(0.3, 0.55, 1.0, alpha), true)

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


## Rumore deterministico in [-1, 1] da due interi e dal seme della salva: le
## frecce sono calcolate una volta sola in _build_volley, quindi la loro forma non
## cambia tra un ridisegno e l'altro (skip, ridimensionamento).
func _volley_noise(index: int, salt: int) -> float:
	var h: int = index * 374761393 + salt * 668265263 + int(_hero_volley.get("seed", 0)) * 2246822519
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xffff) / 32768.0 - 1.0


## Le frecce di una salva: {a, b, delay, flight, height}. Il numero cresce con la
## vita persa; partenza e arrivo sono sparpagliati attorno al centro dei ritratti
## (l'arrivo dentro il ritratto sconfitto) e l'arco è più alto sulle distanze
## lunghe, così le frecce non viaggiano tutte identiche.
func _build_volley(from: Vector2, to: Vector2, target_size: Vector2, damage: int) -> Array[Dictionary]:
	var count := clampi(RESULT_VOLLEY_MIN_ARROWS + damage, RESULT_VOLLEY_MIN_ARROWS, RESULT_VOLLEY_MAX_ARROWS)
	var reach := from.distance_to(to)
	var spread_out := 14.0
	var spread_in := minf(target_size.x, target_size.y) * 0.3
	var arrows: Array[Dictionary] = []
	for i in count:
		var delay := maxf(0.0, RESULT_VOLLEY_STAGGER * (float(i) + 0.4 * _volley_noise(i, 1)) / float(count))
		arrows.append({
			"a": from + Vector2(_volley_noise(i, 2), _volley_noise(i, 3)) * spread_out,
			"b": to + Vector2(_volley_noise(i, 4), _volley_noise(i, 5)) * spread_in,
			"delay": delay,
			"flight": RESULT_VOLLEY_FLIGHT * (1.0 + 0.12 * _volley_noise(i, 6)),
			"height": reach * (0.28 + 0.08 * _volley_noise(i, 7)),
		})
	return arrows


## Posizione della punta a t in [0, 1]: interpolazione lineare più uno scarto
## verticale parabolico, che a schermo si legge come quota (la camera guarda
## dall'alto, quindi "in alto" è solo su nello schermo).
func _volley_point(arrow: Dictionary, t: float) -> Vector2:
	var a: Vector2 = arrow["a"]
	var b: Vector2 = arrow["b"]
	return a.lerp(b, t) + Vector2(0.0, -float(arrow["height"]) * 4.0 * t * (1.0 - t))


## Direzione di volo: la derivata della traiettoria. La freccia sale, si
## appiattisce al vertice e scende in picchiata, come una vera.
func _volley_direction(arrow: Dictionary, t: float) -> Vector2:
	var a: Vector2 = arrow["a"]
	var b: Vector2 = arrow["b"]
	var velocity := (b - a) + Vector2(0.0, -float(arrow["height"]) * 4.0 * (1.0 - 2.0 * t))
	return velocity.normalized() if velocity.length() > 0.001 else Vector2.DOWN


## Salva tra i due ritratti eroe, in coordinate schermo dirette: entrambi i
## ritratti sono figli diretti di questo Control, quindi la loro `position`
## è già nello spazio in cui _draw() lavora, senza passare da project().
##
## Ogni freccia ha tre fasi: attesa (sfalsata), volo ad arco, poi resta
## conficcata nel bersaglio con un anello d'impatto finché la salva sbiadisce.
func _draw_hero_volley() -> void:
	if not bool(_hero_volley.get("active", false)):
		return

	var team: Color = _hero_volley["color"]
	var fade := 1.0 - clampf((_result_time - RESULT_VOLLEY_DURATION * 0.8) / (RESULT_VOLLEY_DURATION * 0.2), 0.0, 1.0)
	for arrow in _hero_volley["arrows"]:
		var flight: float = arrow["flight"]
		var t: float = (_result_time - float(arrow["delay"])) / flight
		if t < 0.0:
			continue
		if t < 1.0:
			# Si ingrandisce un poco al vertice: dà l'idea della quota.
			_draw_arrow(_volley_point(arrow, t), _volley_direction(arrow, t), 1.0 + 0.25 * sin(t * PI), team, fade, true)
			continue
		var landed: Vector2 = arrow["b"]
		_draw_arrow(landed, _volley_direction(arrow, 1.0), 1.0, team, fade, false)
		var impact := (t - 1.0) * flight / RESULT_VOLLEY_IMPACT
		if impact < 1.0:
			var ring := team.lerp(Color.WHITE, 0.4)
			ring.a = (1.0 - impact) * fade
			draw_arc(landed, 4.0 + 14.0 * impact, 0.0, TAU, 20, ring, 2.0 * (1.0 - impact) + 0.5, true)


## Una freccia con la punta in `tip`: asta con contorno scuro (leggibile su
## qualsiasi sfondo), punta metallica e impennaggio nel colore della squadra
## che tira. In volo ha una coda tenue che ne sottolinea la velocità.
func _draw_arrow(tip: Vector2, dir: Vector2, scale: float, team: Color, alpha: float, in_flight: bool) -> void:
	scale *= RESULT_ARROW_SCALE
	var normal := Vector2(-dir.y, dir.x)
	var length := RESULT_ARROW_LENGTH * scale
	var tail := tip - dir * length
	var neck := tip - dir * 7.0 * scale

	if in_flight:
		draw_line(tail, tail - dir * length * 0.9, Color(1, 1, 1, 0.16 * alpha), 1.5 * scale, true)
	draw_line(tail, neck, Color(0, 0, 0, 0.55 * alpha), 4.5 * scale, true)
	draw_line(tail, neck, Color(0.72, 0.55, 0.34, alpha), 2.5 * scale, true)

	var feather := team.lightened(0.1)
	feather.a = alpha
	for side in [-1.0, 1.0]:
		draw_line(tail + dir * 8.0 * scale, tail - dir * 2.0 * scale + normal * 4.5 * scale * side, feather, 2.0 * scale, true)

	var steel := Color(0.88, 0.9, 0.95, alpha)
	draw_colored_polygon(PackedVector2Array([
		tip,
		neck + normal * 3.5 * scale,
		neck - normal * 3.5 * scale,
	]), steel)


func _draw_hero_floater() -> void:
	if _hero_floater.is_empty():
		return
	# Compare quando le prime frecce arrivano, non prima: il numero deve
	# raccontare il colpo, non anticiparlo.
	var span := RESULT_VOLLEY_DURATION - RESULT_VOLLEY_FLIGHT
	var progress: float = clampf((_result_time - RESULT_VOLLEY_FLIGHT) / span, 0.0, 1.0)
	if _result_time < RESULT_VOLLEY_FLIGHT:
		return
	var color := Color(1.0, 0.85, 0.4, 1.0 - progress)
	var position: Vector2 = _hero_floater["at"] + Vector2(0, -30.0 * progress)
	draw_string(_font, position, String(_hero_floater["text"]),
		HORIZONTAL_ALIGNMENT_CENTER, 0, 22, color)


## Annuncio del berserk al centro dello schermo, in dissolvenza. Disegnato qui
## e non come nodo Label perché deve stare sopra la battaglia senza entrare nel
## layout, e perché vive tre secondi: un nodo da aggiungere e rimuovere per
## ogni round sarebbe più codice per lo stesso pixel.
func _draw_berserk_banner() -> void:
	if _berserk_time < 0.0:
		return
	var age := _time - _berserk_time
	if age < 0.0 or age >= BERSERK_BANNER_FADE:
		return

	var progress := age / BERSERK_BANNER_FADE
	var alpha := 1.0 - progress * progress
	# Una spinta di scala solo all'inizio: entra con un colpo e poi si posa.
	var punch: float = 1.0 + 0.18 * maxf(0.0, 1.0 - age / 0.25)
	var font_size := int(roundf(46.0 * punch))
	var banner_text := tr("COMBAT_BERSERKER_TIME")
	var width := _font.get_string_size(banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var at := Vector2((size.x - width) * 0.5, size.y * 0.42)

	# Contorno scuro: la scritta cade su un campo di battaglia colorato e senza
	# stacco si perderebbe proprio nel momento in cui deve farsi leggere.
	var shadow := Color(0.05, 0.02, 0.02, alpha * 0.8)
	for offset in [Vector2(2, 2), Vector2(-2, 2), Vector2(2, -2), Vector2(-2, -2)]:
		draw_string(_font, at + offset, banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, shadow)
	var color := BERSERK_COLOR
	color.a = alpha
	draw_string(_font, at, banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw_clock() -> void:
	var y := size.y - 10.0
	# Il moltiplicatore compare solo dove esiste ancora un comando per cambiarlo
	# (la vista spettatore): nella propria battaglia il tempo lo racconta la barra.
	var text := "%.1fs / %.1fs" % [minf(_time, _duration), _duration]
	if not is_equal_approx(speed, 1.0):
		text += "   ×%.0f" % speed
	draw_string(_font, Vector2(6, y), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.72, 0.72, 0.80))
