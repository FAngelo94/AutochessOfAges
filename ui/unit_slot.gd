class_name UnitSlot
extends Button

## Una casella che mostra un'unità: negozio, griglia di schieramento, panchina,
## collezione.
##
## Al posto del nome scritto mostra il modello 3D dell'unità, preso da
## Portraits. Il nome resta nel suggerimento: la figura si riconosce a colpo
## d'occhio, il nome serve solo a chi si ferma a leggere.
##
## Se il ritratto non è ancora pronto — o non lo sarà mai, come nei test senza
## schermo — compare il nome abbreviato. Nessuna schermata dipende dal
## rendering 3D per restare utilizzabile.

enum Badge { NONE, COST, STARS }

## Le caselle del campo di battaglia sono esagoni; negozio, panchina e
## collezione restano rettangoli. Il disegno è qui e non in Style perché uno
## StyleBox sa fare solo rettangoli con gli angoli arrotondati: per una forma
## diversa serve disegnarla, e insieme al disegno va cambiata anche la zona
## sensibile al clic, che è responsabilità del pulsante.
var hexagonal := false

var unit_id: String = ""

var _fill := Color.TRANSPARENT
var _border := Color.TRANSPARENT
var _border_width := 2.0

var _portrait: TextureRect
var _fallback: Label
var _badge: Label
var _badge_mode: int = Badge.NONE

## L'autoload si prende dall'albero e non per nome globale: gli script
## compilati da riga di comando non lo vedrebbero. In _init il nodo non è
## ancora nell'albero, quindi si risolve in _ready.
var _portraits: Node


func _init() -> void:
	# I figli non devono intercettare il clic: la casella è il pulsante.
	clip_contents = true

	_portrait = TextureRect.new()
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait.visible = false
	add_child(_portrait)

	_fallback = Label.new()
	_fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_fallback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fallback.add_theme_font_size_override("font_size", 16)
	_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fallback)

	# Costo o stelle, ancorati in basso: restano leggibili sopra la figura.
	_badge = Label.new()
	_badge.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_badge.offset_top = -28.0
	_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_badge.add_theme_font_size_override("font_size", 18)
	_badge.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_badge.add_theme_constant_override("outline_size", 5)
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_badge)


func _ready() -> void:
	_portraits = get_node("/root/Portraits")
	_portraits.portrait_ready.connect(_on_portrait_ready)
	# La casella può essere stata riempita prima di entrare nell'albero: ora
	# che il magazzino dei ritratti è raggiungibile, si riprova.
	if unit_id != "":
		var def := GameData.unit(unit_id)
		if def != null:
			_apply_portrait(def)


## Svuota la casella lasciando solo lo sfondo.
func show_empty(fill: Color, border: Color) -> void:
	unit_id = ""
	tooltip_text = ""
	_portrait.visible = false
	_portrait.texture = null
	_fallback.text = ""
	_badge.text = ""
	_apply_style(fill, border, 1)


## Mostra un'unità. `star` a 0 significa "non ancora in campo" (il negozio),
## dove al posto delle stelle si scrive il costo.
func show_unit(def: UnitDef, star: int, badge_mode: int, fill: Color, border: Color,
		border_width: int = 2, tooltip: String = "") -> void:
	unit_id = def.id
	_badge_mode = badge_mode
	tooltip_text = tooltip if tooltip != "" else def.display_name

	_apply_style(fill, border, border_width)
	_apply_portrait(def)

	match badge_mode:
		Badge.COST:
			_badge.text = "%d oro" % def.cost
			_badge.add_theme_color_override("font_color", Style.rarity_color(def.cost))
		Badge.STARS:
			_badge.text = "★".repeat(star)
			_badge.add_theme_color_override("font_color", Style.rarity_color(def.cost))
		_:
			_badge.text = ""


## Applica i colori della casella: come rettangolo li affida al tema, come
## esagono se li tiene per disegnarli e azzera gli sfondi del tema, altrimenti
## il rettangolo comparirebbe sotto l'esagono.
func _apply_style(fill: Color, border: Color, border_width: int) -> void:
	if not hexagonal:
		Style.apply_button(self, fill, border, border_width)
		return
	_fill = fill
	_border = border
	_border_width = float(border_width)
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	queue_redraw()


func _draw() -> void:
	if not hexagonal:
		return
	var points := _hex_points()
	draw_colored_polygon(points, _fill)
	var outline := points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, _border, _border_width, true)


## Esagono con la punta in alto inscritto nella casella, rientrato di un paio
## di pixel: il rientro è ciò che separa visivamente due celle adiacenti, dato
## che il campo è disposto per combaciare senza spazi.
func _hex_points() -> PackedVector2Array:
	const INSET := 1.5
	var centre := size * 0.5
	var half_width := size.x * 0.5 - INSET
	var half_height := size.y * 0.5 - INSET
	return PackedVector2Array([
		centre + Vector2(0.0, -half_height),
		centre + Vector2(half_width, -half_height * 0.5),
		centre + Vector2(half_width, half_height * 0.5),
		centre + Vector2(0.0, half_height),
		centre + Vector2(-half_width, half_height * 0.5),
		centre + Vector2(-half_width, -half_height * 0.5),
	])


## Zona sensibile al clic. Le righe di esagoni si incastrano, quindi i
## rettangoli che li contengono si sovrappongono: senza questo controllo la
## cella sopra ruberebbe i clic destinati agli angoli di quella sotto.
func _has_point(point: Vector2) -> bool:
	if not hexagonal:
		return Rect2(Vector2.ZERO, size).has_point(point)
	var centre := size * 0.5
	var dx: float = absf(point.x - centre.x) / maxf(centre.x, 0.001)
	var dy: float = absf(point.y - centre.y) / maxf(centre.y, 0.001)
	return dx <= 1.0 and dy <= 1.0 - 0.5 * dx


func _apply_portrait(def: UnitDef) -> void:
	var texture: Texture2D = _portraits.texture_for(def.id) if _portraits != null else null
	_portrait.texture = texture
	_portrait.visible = texture != null

	# Il nome resta visibile finché la figura non c'è: una casella vuota
	# sarebbe indistinguibile da uno slot libero.
	_fallback.visible = texture == null
	_fallback.text = "" if texture != null else _short_name(def.display_name)
	_fallback.add_theme_color_override("font_color", Style.origin_color(def.origin))


func _on_portrait_ready(ready_id: String) -> void:
	if ready_id == unit_id:
		var def := GameData.unit(unit_id)
		if def != null:
			_apply_portrait(def)


## Nomi come "Fromboliere gallico" non entrano in una casella: si tiene la
## prima parola, che è quella che identifica l'unità.
static func _short_name(display_name: String) -> String:
	if display_name.length() <= 12:
		return display_name
	var first := display_name.split(" ")[0]
	return first if first.length() <= 12 else first.left(11) + "."
