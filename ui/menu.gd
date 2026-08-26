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

const MODE_CPU := "cpu"
const MODE_PVP := "pvp"

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

## Gli autoload si prendono dall'albero e non per nome globale: gli script
## compilati da riga di comando (test headless) non li vedrebbero.
var _store: Node
var _profile: Node
var _store_panel: StorePanel
var _collection_panel: CollectionPanel
var _mode_panel: Panel
var _mode_button: Button
var _mode_option_buttons: Dictionary = {}
var _match_mode: String = MODE_CPU


func _ready() -> void:
	GameData.ensure_loaded()
	_store = get_node("/root/Store")
	_profile = get_node("/root/Profile")
	_build()

	# I ritratti 3D si generano un fotogramma per unità: farlo qui, mentre il
	# giocatore guarda il menu, fa sì che collezione e partita li trovino già
	# pronti invece di vederli comparire a uno a uno.
	var ids: Array = []
	for def in GameData.all_units():
		ids.append(def.id)
	get_node("/root/Portraits").preload_units(ids)


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
	column.add_child(_mode_section())
	column.add_child(_spacer(6))
	column.add_child(_play_button())
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

	_build_mode_panel()
	_update_mode_button()


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
	subtitle.text = "Romani · Galli · Teutonici"
	subtitle.add_theme_font_size_override("font_size", 21)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", Style.TEXT_DIM)
	wrap.add_child(subtitle)

	return wrap


## Un solo pulsante, non due (cpu/pvp) affiancati: la scelta vera avviene nella
## modale, qui serve solo dire quale modalità partirà premendo GIOCA.
func _mode_section() -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 10)
	wrap.add_child(_section("MODALITÀ"))

	_mode_button = Button.new()
	_mode_button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	_mode_button.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(_mode_button, Style.PLATE, Style.PLATE_DARK, 18, 6)
	_mode_button.pressed.connect(func() -> void: _mode_panel.visible = true)
	wrap.add_child(_mode_button)
	_update_mode_button()

	return wrap


## Modale di selezione: due carte, una per modalità. Vive nascosta nell'albero
## come i pannelli di negozio e collezione, così non serve ricostruirla ogni
## volta che si apre.
func _build_mode_panel() -> void:
	_mode_panel = Panel.new()
	_mode_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mode_panel.add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	_mode_panel.visible = false
	add_child(_mode_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	_mode_panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)

	var title := Label.new()
	title.text = "SCEGLI MODALITÀ"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(title)

	column.add_child(_mode_option(MODE_CPU, "🖥️  Contro il computer",
		"Affronta subito degli avversari controllati dal gioco."))
	column.add_child(_mode_option(MODE_PVP, "👥  Contro giocatori",
		"In arrivo: per ora seleziona questa modalità solo in anteprima."))

	column.add_child(_grow())

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 18, 6)
	close.pressed.connect(func() -> void: _mode_panel.visible = false)
	column.add_child(close)


func _mode_option(mode: String, label_text: String, hint_text: String) -> Control:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 4)

	var button := Button.new()
	button.text = label_text
	button.custom_minimum_size = Vector2(0, Style.TOUCH_PRIMARY)
	button.add_theme_font_size_override("font_size", 26)
	button.pressed.connect(func() -> void: _on_mode_pressed(mode))
	card.add_child(button)
	_mode_option_buttons[mode] = button

	var hint := Label.new()
	hint.text = hint_text
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", Style.TEXT_DIM)
	card.add_child(hint)

	return card


## L'unico pulsante che deve essere impossibile da mancare: più alto, più caldo
## e più in basso di tutto il resto, dove il pollice arriva senza spostare la mano.
func _play_button() -> Button:
	var play := Button.new()
	play.text = "GIOCA"
	play.custom_minimum_size = Vector2(0, Style.TOUCH_PRIMARY)
	play.add_theme_font_size_override("font_size", 44)
	play.add_theme_color_override("font_color", Style.INK)
	play.add_theme_color_override("font_hover_color", Style.INK)
	play.add_theme_color_override("font_pressed_color", Style.INK)
	Style.apply_plate(play, Style.GOLD, Style.GOLD_DEEP, 22, 9)
	play.pressed.connect(_on_play_pressed)
	return play


func _nav_bar() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	for entry in [["🎴  Collezione", _on_collection_pressed], ["🛒  Negozio", _on_store_pressed]]:
		var button := Button.new()
		button.text = String(entry[0])
		button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 24)
		Style.apply_plate(button, Style.BLUE, Style.BLUE_DEEP, 18, 6)
		button.pressed.connect(entry[1] as Callable)
		row.add_child(button)

	return row


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
		# Non implementata: lo si dice invece di far finta di partire.
		var notice := AcceptDialog.new()
		notice.dialog_text = "La modalità contro giocatori arriva in un prossimo aggiornamento."
		notice.title = "In arrivo"
		add_child(notice)
		notice.confirmed.connect(notice.queue_free)
		notice.canceled.connect(notice.queue_free)
		notice.popup_centered()
		return

	get_tree().change_scene_to_file(GAME_SCENE)


func _on_collection_pressed() -> void:
	_collection_panel.open()


func _on_store_pressed() -> void:
	_store_panel.open()


func _on_mode_pressed(mode: String) -> void:
	_match_mode = mode
	_update_mode_button()
	_mode_panel.visible = false


func _update_mode_button() -> void:
	if _match_mode == MODE_PVP:
		_mode_button.text = "👥  Contro giocatori"
	else:
		_mode_button.text = "🖥️  Contro il computer"

	for mode in _mode_option_buttons:
		var button: Button = _mode_option_buttons[mode]
		var selected: bool = mode == _match_mode
		Style.apply_plate(button, Style.GOLD if selected else Style.PLATE, Style.GOLD_DEEP if selected else Style.PLATE_DARK, 18, 6)
		button.add_theme_color_override("font_color", Style.INK if selected else Style.TEXT_DIM)
