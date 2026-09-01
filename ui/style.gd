class_name Style
extends RefCounted

## Palette e stili condivisi dall'interfaccia.
##
## Sta tutto qui per una ragione pratica: i colori di rarità e di civiltà
## compaiono in tre punti diversi (negozio, griglia, panchina) e devono
## coincidere, altrimenti il giocatore impara due codici colore contraddittori.

const BACKGROUND := Color(0.09, 0.09, 0.12)
const PANEL := Color(0.13, 0.13, 0.17)
const CELL := Color(0.16, 0.16, 0.21)
## La fila a contatto col nemico: chi ci mette le unità deve sapere cosa fa.
const FRONT_LINE := Color(0.21, 0.17, 0.17)
const SELECTED := Color(0.95, 0.78, 0.32)
const TEXT_DIM := Color(0.62, 0.62, 0.7)

## Colori di rarità per costo, la convenzione del genere: grigio, verde, blu,
## viola, oro. Indice 0 = costo 1.
const RARITY := [
	Color(0.62, 0.64, 0.68),
	Color(0.42, 0.78, 0.45),
	Color(0.34, 0.62, 0.92),
	Color(0.72, 0.45, 0.9),
	Color(0.95, 0.75, 0.25),
]

const ORIGIN := {
	"roman": Color(0.85, 0.35, 0.32),
	"gaul": Color(0.45, 0.75, 0.45),
	"teuton": Color(0.45, 0.58, 0.9),
}


static func rarity_color(cost: int) -> Color:
	return RARITY[clampi(cost - 1, 0, RARITY.size() - 1)]


static func origin_color(origin_id: String) -> Color:
	return ORIGIN.get(origin_id, Color(0.7, 0.7, 0.75))


## Ogni pulsante che passa da apply_button/apply_plate — cioè praticamente tutti
## — suona un click quando premuto. La guardia is_connected regge i ri-styling
## ripetuti (UnitSlot si ristila a ogni refresh, alcuni pulsanti cambiano
## piastra a runtime).
static func _wire_click(button: Button) -> void:
	if not button.pressed.is_connected(_play_click):
		button.pressed.connect(_play_click)


static func _play_click() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var sfx := tree.root.get_node_or_null("/root/Sfx") if tree != null else null
	if sfx != null:
		sfx.play("click")


static func box(fill: Color, border: Color, border_width: int = 1, radius: int = 4) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	return style


## Applica a un pulsante lo stesso stile in tutti i suoi stati: senza, Godot
## rimette il tema predefinito appena il mouse passa sopra e il colore scelto
## sparisce proprio mentre lo si guarda.
static func apply_button(button: Button, fill: Color, border: Color, border_width: int = 1) -> void:
	_wire_click(button)
	button.add_theme_stylebox_override("normal", box(fill, border, border_width))
	button.add_theme_stylebox_override("hover", box(fill.lightened(0.08), border.lightened(0.2), border_width))
	button.add_theme_stylebox_override("pressed", box(fill.darkened(0.1), border, border_width))
	button.add_theme_stylebox_override("focus", box(fill, border, border_width))
	button.add_theme_stylebox_override("disabled", box(fill.darkened(0.25), border.darkened(0.35), border_width))


# --------------------------------------------------------------------------
# Metriche mobile
# --------------------------------------------------------------------------
#
# Il viewport di base è 720×1280 (portrait). Su un telefono 1080p il fattore di
# scala è 1.5, quindi 96 px logici ≈ 64 px fisici ≈ un polpastrello. Sotto i 96
# i pulsanti si sbagliano: è la soglia, non un suggerimento.

const TOUCH_MIN := 96
const TOUCH_PRIMARY := 132
const GUTTER := 28

## Fondale del menu: blu notte in alto, più caldo verso il basso, così il
## pulsante d'oro in fondo stacca invece di annegare nel grigio.
const SKY_TOP := Color(0.07, 0.10, 0.20)
const SKY_BOTTOM := Color(0.16, 0.13, 0.22)
const PLATE := Color(0.18, 0.20, 0.32)
const PLATE_DARK := Color(0.11, 0.13, 0.22)
const GOLD := Color(0.98, 0.78, 0.28)
const GOLD_DEEP := Color(0.72, 0.48, 0.10)
const BLUE := Color(0.29, 0.55, 0.92)
const BLUE_DEEP := Color(0.16, 0.31, 0.60)
const INK := Color(0.06, 0.07, 0.12)

## Pietra della cornice del menu: la facciata del castello è disegnata a
## runtime, quindi i suoi toni stanno qui insieme al resto della palette invece
## che sparsi nel codice del disegno. Sono volutamente desaturati e vicini al
## fondale: la cornice deve dare profondità, non rubare attenzione ai pulsanti.
const STONE := Color(0.27, 0.26, 0.33)
const STONE_LIT := Color(0.37, 0.36, 0.44)
const STONE_DARK := Color(0.17, 0.17, 0.23)
const MORTAR := Color(0.11, 0.11, 0.16)
## Luce delle torce: l'unico caldo del fondale, e per questo il colore che
## guida l'occhio verso il centro dello schermo.
const TORCH := Color(1.0, 0.66, 0.30)


## Pulsante "a piastra": faccia piena, bordo inferiore spesso e scuro. È il
## trucco che dà il rilievo dei bottoni da auto battler senza un solo asset —
## StyleBoxFlat non fa gradienti, ma i bordi per lato sì.
static func plate(fill: Color, edge: Color, radius: int = 18, lip: int = 6) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = edge
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = lip
	style.set_corner_radius_all(radius)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style


## Come apply_button ma per le piastre: da premuto la faccia scende sul labbro
## inferiore, che è il feedback che su touch sostituisce l'hover inesistente.
static func apply_plate(button: Button, fill: Color, edge: Color, radius: int = 18, lip: int = 6) -> void:
	_wire_click(button)
	button.add_theme_stylebox_override("normal", plate(fill, edge, radius, lip))
	button.add_theme_stylebox_override("hover", plate(fill.lightened(0.10), edge.lightened(0.12), radius, lip))
	var down := plate(fill.darkened(0.12), edge, radius, 2)
	down.content_margin_top = 14
	button.add_theme_stylebox_override("pressed", down)
	button.add_theme_stylebox_override("focus", plate(fill, edge, radius, lip))
	button.add_theme_stylebox_override("disabled", plate(fill.darkened(0.30), edge.darkened(0.40), radius, lip))


## Fondale sfumato come TextureRect: un ColorRect piatto su schermo lungo fa
## sembrare il menu una pagina vuota con roba in mezzo.
static func backdrop(top: Color, bottom: Color) -> TextureRect:
	var gradient := Gradient.new()
	gradient.set_color(0, top)
	gradient.set_color(1, bottom)

	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 8
	texture.height = 256
	texture.fill_from = Vector2(0, 0)
	texture.fill_to = Vector2(0, 1)

	var rect := TextureRect.new()
	rect.texture = texture
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


## Moneta d'oro disegnata: bordo scuro, faccia piena e un riflesso in alto a
## sinistra — lo stesso trucco dei bracieri del menu, tre draw_circle e nessun
## asset. Sostituisce il carattere ⛁, che non è un glifo di moneta (è un pezzo
## della dama) e che fuori dal font di sistema esce come rettangolo vuoto.
static func draw_coin(canvas: Control, center: Vector2, radius: float) -> void:
	canvas.draw_circle(center, radius, GOLD_DEEP)
	canvas.draw_circle(center, radius * 0.78, GOLD)
	canvas.draw_circle(center - Vector2(radius * 0.28, radius * 0.28),
		radius * 0.20, GOLD.lightened(0.45))


## Un Control quadrato che disegna solo la moneta, da infilare dove servirebbe
## un glifo. Stesso schema del fondale del castello: draw connesso su un Control
## nudo, resized -> queue_redraw.
static func coin(diameter: float = 22.0) -> Control:
	var node := Control.new()
	node.custom_minimum_size = Vector2(diameter, diameter)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.draw.connect(func() -> void:
		draw_coin(node, node.size * 0.5, minf(node.size.x, node.size.y) * 0.5))
	node.resized.connect(node.queue_redraw)
	return node
