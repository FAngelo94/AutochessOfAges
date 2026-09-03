class_name CastleBackdrop
extends Control

## Ingresso di un castello disegnato a runtime: due colonne di pietra a tutta
## altezza sui bordi e un arco a incorniciare il titolo. Zero asset su disco.
##
## Sta qui e non più dentro menu.gd perché lo condividono la home e la
## schermata di login: sono la stessa stanza, e il giocatore deve vedere che
## l'accesso avviene già dentro al gioco.
##
## Le costanti sono pubbliche: chi lo usa ne ricava i margini del proprio
## contenuto, così niente finisce mai sopra alla pietra.

## Geometria della facciata. Sono costanti e non frazioni dello schermo perché
## il viewport è a larghezza fissa (720, stretch "keep_width"): solo l'altezza
## cambia da telefono a telefono, e di quella si occupano lo spaziatore
## elastico e le colonne, che scendono fino in fondo.
const COLUMN_W := 58.0
## Coronamento merlato: la fascia di cielo in cima che i merli interrompono.
const FACADE_TOP := 26.0
## Linea d'imposta dell'arco: sopra c'è la muratura, sotto comincia il vano
## d'ingresso in cui vive il contenuto di chi lo usa.
const SPRING_Y := 196.0
const FLOOR_H := 46.0


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	draw.connect(_draw_castle)
	resized.connect(queue_redraw)


func _draw_castle() -> void:
	var s := size
	if s.x <= 0.0 or s.y <= 0.0:
		return

	# Vano d'ingresso: mezza ellisse fra le due colonne. Ellisse e non
	# semicerchio perché il raggio di un arco a tutto sesto largo 600 px
	# arriverebbe ben oltre il bordo alto dello schermo.
	var cx := s.x * 0.5
	var half := cx - COLUMN_W
	var rise := (SPRING_Y - FACADE_TOP) * 0.85

	_draw_merlons(s)
	_draw_facade(s, cx, half, rise)
	_draw_columns(s)
	_draw_arch(cx, half, rise)
	_draw_floor(s)
	_draw_torches(s)


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
func _draw_merlons(s: Vector2) -> void:
	var x := 0.0
	while x < s.x:
		draw_rect(Rect2(Vector2(x, 0.0), Vector2(30.0, FACADE_TOP + 2.0)), Style.STONE)
		draw_rect(Rect2(Vector2(x, 0.0), Vector2(30.0, 4.0)), Style.STONE_LIT)
		x += 52.0


## La muratura si riempie a strisce verticali: il profilo dell'arco esce esatto
## per costruzione, senza dover triangolare un poligono concavo.
func _draw_facade(s: Vector2, cx: float, half: float, rise: float) -> void:
	var step := 4.0
	var x := 0.0
	while x < s.x:
		var bottom := _facade_bottom(x + step * 0.5, cx, half, rise)
		draw_rect(Rect2(Vector2(x, FACADE_TOP), Vector2(step + 1.0, bottom - FACADE_TOP)), Style.STONE)
		x += step

	# Corsi orizzontali e giunti sfalsati: bastano poche linee di malta per
	# trasformare una campitura piatta in pietra squadrata.
	var row := 0
	var y := FACADE_TOP + 30.0
	while y < SPRING_Y:
		var open_half := _opening_half(y, half, rise)
		draw_line(Vector2(0.0, y), Vector2(cx - open_half, y), Style.MORTAR, 2.0)
		draw_line(Vector2(cx + open_half, y), Vector2(s.x, y), Style.MORTAR, 2.0)

		var joint := 34.0 + (row % 2) * 36.0
		while joint < s.x:
			if absf(joint - cx) > open_half + 8.0:
				var stop: float = minf(y + 30.0, _facade_bottom(joint, cx, half, rise))
				draw_line(Vector2(joint, y), Vector2(joint, stop), Style.MORTAR, 2.0)
			joint += 72.0

		row += 1
		y += 30.0


## Le due colonne. Il lato interno è schiarito e quello esterno incupito: è
## l'unico modo, senza gradienti, per far sembrare tonda una campitura piatta.
func _draw_columns(s: Vector2) -> void:
	var base_top := s.y - FLOOR_H - 64.0

	for side in range(2):
		var x0: float = 0.0 if side == 0 else s.x - COLUMN_W
		var inner: float = x0 + COLUMN_W - 7.0 if side == 0 else x0
		var outer: float = x0 if side == 0 else x0 + COLUMN_W - 9.0

		draw_rect(Rect2(Vector2(x0, SPRING_Y), Vector2(COLUMN_W, s.y - SPRING_Y)), Style.STONE)
		draw_rect(Rect2(Vector2(outer, SPRING_Y), Vector2(9.0, s.y - SPRING_Y)), Style.STONE_DARK)
		draw_rect(Rect2(Vector2(inner, SPRING_Y), Vector2(7.0, s.y - SPRING_Y)), Style.STONE_LIT)

		# Scanalature: il dettaglio che distingue una colonna da un pilastro.
		for i in range(3):
			var fx := x0 + COLUMN_W * (0.28 + 0.22 * i)
			draw_line(Vector2(fx, SPRING_Y + 36.0), Vector2(fx, base_top - 6.0), Style.MORTAR, 2.0)

		# Capitello sotto l'imposta dell'arco e base sopra il pavimento: senza,
		# le colonne sembrerebbero due strisce tagliate dai bordi dello schermo.
		draw_rect(Rect2(Vector2(x0 - 12.0, SPRING_Y - 8.0), Vector2(COLUMN_W + 24.0, 12.0)), Style.STONE_LIT)
		draw_rect(Rect2(Vector2(x0 - 7.0, SPRING_Y + 4.0), Vector2(COLUMN_W + 14.0, 22.0)), Style.STONE)
		draw_line(Vector2(x0 - 7.0, SPRING_Y + 26.0), Vector2(x0 + COLUMN_W + 7.0, SPRING_Y + 26.0), Style.MORTAR, 2.0)

		draw_rect(Rect2(Vector2(x0 - 7.0, base_top), Vector2(COLUMN_W + 14.0, 26.0)), Style.STONE)
		draw_rect(Rect2(Vector2(x0 - 12.0, base_top + 26.0), Vector2(COLUMN_W + 24.0, s.y - base_top - 26.0)), Style.STONE_LIT.darkened(0.3))

		# Scudo appeso al fusto: un fermo per l'occhio a metà colonna, dove
		# altrimenti resterebbe mezzo schermo di pietra vuota.
		var sy := (SPRING_Y + base_top) * 0.5
		var mid := x0 + COLUMN_W * 0.5
		draw_circle(Vector2(mid, sy), 18.0, Style.STONE_DARK)
		draw_circle(Vector2(mid, sy), 15.0, Style.GOLD_DEEP.darkened(0.45))
		draw_line(Vector2(mid - 10.0, sy), Vector2(mid + 10.0, sy), Style.GOLD_DEEP, 3.0)
		draw_line(Vector2(mid, sy - 10.0), Vector2(mid, sy + 10.0), Style.GOLD_DEEP, 3.0)


## Ghiera dell'arco: conci radiali, chiave di volta e un filo d'oro sul bordo,
## che è quello che fa leggere l'ingresso come una porta cerimoniale.
func _draw_arch(cx: float, half: float, rise: float) -> void:
	var segments := 28
	var curve := PackedVector2Array()
	for i in range(segments + 1):
		var t: float = PI - PI * i / float(segments)
		curve.append(Vector2(cx + cos(t) * half, SPRING_Y - sin(t) * rise))

	for i in range(2, segments - 1, 2):
		var p: Vector2 = curve[i]
		var dir := (p - Vector2(cx, SPRING_Y)).normalized()
		draw_line(p, p + dir * 30.0, Style.MORTAR, 2.0)

	draw_polyline(curve, Style.MORTAR, 4.0, true)
	draw_polyline(curve, Style.GOLD_DEEP.darkened(0.1), 2.0, true)

	var crown := SPRING_Y - rise
	var keystone := PackedVector2Array([
		Vector2(cx - 17.0, crown + 6.0),
		Vector2(cx + 17.0, crown + 6.0),
		Vector2(cx + 25.0, crown - 32.0),
		Vector2(cx - 25.0, crown - 32.0),
	])
	draw_colored_polygon(keystone, Style.STONE_LIT)
	draw_polyline(keystone, Style.MORTAR, 2.0, true)
	draw_line(Vector2(cx, crown - 24.0), Vector2(cx, crown - 2.0), Style.GOLD_DEEP, 3.0)


## Lastricato in fondo: chiude la prospettiva sotto ai pulsanti, così le
## colonne poggiano su qualcosa invece di scendere nel vuoto.
func _draw_floor(s: Vector2) -> void:
	var y := s.y - FLOOR_H
	draw_rect(Rect2(Vector2(0.0, y), Vector2(s.x, FLOOR_H)), Style.STONE.darkened(0.35))
	draw_line(Vector2(0.0, y), Vector2(s.x, y), Style.STONE_LIT, 2.0)

	# Giunti in fuga verso il centro: suggeriscono la profondità del passaggio.
	var jx := 0.0
	while jx < s.x:
		var lean: float = (jx - s.x * 0.5) / s.x * 44.0
		draw_line(Vector2(jx, y), Vector2(jx + lean, s.y), Style.MORTAR, 2.0)
		jx += 96.0


## Torce sulle colonne: l'unica sorgente calda dello schermo. Portano l'occhio
## verso il centro, dove sta il titolo, e staccano la pietra dal cielo.
func _draw_torches(s: Vector2) -> void:
	for side in range(2):
		var x: float = COLUMN_W * 0.5 if side == 0 else s.x - COLUMN_W * 0.5
		var y := SPRING_Y + 168.0

		# L'alone è fatto di cerchi molto trasparenti sovrapposti: è il
		# gradiente che draw_circle non ha, e costa sei chiamate invece di una
		# texture da tenere in memoria.
		var glow := Style.TORCH
		for i in range(6):
			draw_circle(Vector2(x, y), 130.0 - i * 20.0, Color(glow.r, glow.g, glow.b, 0.035))

		# Braccio e coppa della torcia.
		draw_line(Vector2(x, y + 34.0), Vector2(x, y + 10.0), Style.STONE_DARK, 6.0)
		draw_colored_polygon(PackedVector2Array([
			Vector2(x - 16.0, y + 8.0),
			Vector2(x + 16.0, y + 8.0),
			Vector2(x + 9.0, y + 24.0),
			Vector2(x - 9.0, y + 24.0),
		]), Style.STONE_DARK)

		# Fiamma a goccia: un cerchio sembrerebbe una lampadina.
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, y - 34.0),
			Vector2(x + 14.0, y - 6.0),
			Vector2(x + 10.0, y + 9.0),
			Vector2(x, y + 13.0),
			Vector2(x - 10.0, y + 9.0),
			Vector2(x - 14.0, y - 6.0),
		]), Style.TORCH)
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, y - 18.0),
			Vector2(x + 7.0, y - 2.0),
			Vector2(x, y + 8.0),
			Vector2(x - 7.0, y - 2.0),
		]), Color(1.0, 0.94, 0.76))
