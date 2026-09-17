class_name LeaderboardPanel
extends Panel

## Classifica dei giocatori per mmr.
##
## L'mmr lo possiede solo il server (player_stats su Postgres), quindi la lista
## arriva sempre dal master (LEADERBOARD_REQUEST → RPC leaderboard, 0006) e non
## esiste una versione locale: da ospite o offline il pannello lo dice invece di
## mostrare una classifica vuota che sembrerebbe vera.
##
## Struttura presa da ui/history_panel.gd — stesso `open()`, stesso segnale
## `closed`, stessa targa di chiusura in fondo.

signal closed

## Vero quando il pannello è una pagina della home a schede (ui/menu.gd):
## niente pulsante Chiudi — si esce cambiando scheda — e resta visibile dentro
## la sua pagina. Va impostato prima di add_child, che fa partire _ready().
var embedded := false

## Quanti giocatori chiedere. Il tetto vero lo impone il master (LEADERBOARD_MAX).
const REMOTE_LIMIT := 100

const SILVER := Color(0.78, 0.8, 0.86)
const BRONZE := Color(0.8, 0.52, 0.3)

var _list: VBoxContainer
var _status: Label
var _requested := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	visible = embedded
	_build()


func open() -> void:
	visible = true
	_fetch()


func _build() -> void:
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 12 if embedded else Style.safe_top_margin())
	margin.add_theme_constant_override("margin_bottom", 8 if embedded else 18)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.text = tr("LEADERBOARD_TITLE")
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(title)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 18)
	_status.add_theme_color_override("font_color", Style.TEXT_DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)

	if not embedded:
		var close := Button.new()
		close.text = tr("UI_CLOSE")
		close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
		close.add_theme_font_size_override("font_size", 26)
		Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 18, 6)
		close.pressed.connect(func() -> void:
			visible = false
			closed.emit())
		column.add_child(close)


func _fetch() -> void:
	var auth := get_node_or_null("/root/Auth")
	if auth == null or not auth.has_method("request_leaderboard") or not auth.is_logged_in():
		_clear()
		_status.text = tr("LEADERBOARD_LOGIN_REQUIRED")
		return
	if _requested:
		return
	_requested = true
	_status.text = tr("LEADERBOARD_LOADING")
	auth.request_leaderboard(REMOTE_LIMIT, func(ok: bool, data: Dictionary) -> void:
		_requested = false
		if not ok:
			_clear()
			_status.text = tr("LEADERBOARD_UNREACHABLE")
			return
		show_data(data))


## Disegna una risposta LEADERBOARD_DATA. Pubblico perché gli strumenti di
## screenshot possano mostrarla senza un server.
func show_data(data: Dictionary) -> void:
	_clear()
	var top: Array = data.get("top", []) if data.get("top") is Array else []
	var me: Dictionary = data.get("me", {}) if data.get("me") is Dictionary else {}

	if top.is_empty():
		_status.text = tr("LEADERBOARD_EMPTY")
		return

	var me_listed := false
	for entry in top:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		me_listed = me_listed or bool(entry.get("is_me", false))
		_list.add_child(_player_row(entry))

	# Fuori dai primi cento la propria riga compare lo stesso, staccata: è
	# l'unica che interessa davvero a chi apre la classifica.
	if not me.is_empty() and not me_listed:
		var gap := Label.new()
		gap.text = "…"
		gap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		gap.add_theme_font_size_override("font_size", 22)
		gap.add_theme_color_override("font_color", Style.TEXT_DIM)
		_list.add_child(gap)
		_list.add_child(_player_row(me))

	if me.is_empty():
		_status.text = tr("LEADERBOARD_PLAY_TO_ENTER")
	else:
		_status.text = tr("LEADERBOARD_YOUR_POSITION") % _ordinal(int(me.get("position", 0)))


func _clear() -> void:
	# Staccati subito e non solo messi in coda: una seconda risposta nello
	# stesso frame non deve contare le righe vecchie.
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()


func _player_row(entry: Dictionary) -> Control:
	var position := int(entry.get("position", 0))
	var is_me := bool(entry.get("is_me", false))
	var mmr := int(entry.get("mmr", 0))

	var frame := PanelContainer.new()
	var border := Style.GOLD if is_me else _podium_color(position)
	frame.add_theme_stylebox_override("panel",
		Style.box(Style.PLATE_DARK, border, 3 if is_me else 2, 10))

	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 12)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 10)
	frame.add_child(pad)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	pad.add_child(line)

	var badge := Label.new()
	badge.text = _badge_text(position)
	badge.custom_minimum_size = Vector2(58, 0)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", 30 if position <= 3 else 24)
	badge.add_theme_color_override("font_color", _podium_color(position))
	line.add_child(badge)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 2)
	line.add_child(column)

	var name_label := Label.new()
	name_label.text = String(entry.get("username", "—")) + (tr("LEADERBOARD_YOU_SUFFIX") if is_me else "")
	name_label.add_theme_font_size_override("font_size", 20)
	if is_me:
		name_label.add_theme_color_override("font_color", Style.GOLD)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	column.add_child(name_label)

	var detail := Label.new()
	var bits: Array = []
	# Il grado compare solo se data/balance.json ne definisce: senza "ranks"
	# rank_for_mmr() torna "—", che in ogni riga sarebbe solo rumore.
	var rank_name := String(GameData.rank_for_mmr(mmr).get("name", "—"))
	if rank_name != "—":
		bits.append(rank_name)
	bits.append(tr("LEADERBOARD_MATCHES_PLAYED") % int(entry.get("matches_played", 0)))
	bits.append(tr("LEADERBOARD_WINS") % int(entry.get("wins", 0)))
	detail.text = "  ·  ".join(bits)
	detail.add_theme_font_size_override("font_size", 15)
	detail.add_theme_color_override("font_color", Style.TEXT_DIM)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(detail)

	var mmr_label := Label.new()
	mmr_label.text = "%d" % mmr
	mmr_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	mmr_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mmr_label.add_theme_font_size_override("font_size", 22)
	mmr_label.add_theme_color_override("font_color", Style.GOLD)
	line.add_child(mmr_label)

	return frame


func _badge_text(position: int) -> String:
	match position:
		1: return "🥇"
		2: return "🥈"
		3: return "🥉"
	return _ordinal(position) if position > 0 else "—"


## Indicatore ordinale di posizione ("3°" in italiano, "#3" in inglese): la
## convenzione cambia per lingua, non è solo un simbolo appiccicato al numero.
func _ordinal(position: int) -> String:
	return tr("LEADERBOARD_ORDINAL") % position


func _podium_color(position: int) -> Color:
	match position:
		1: return Style.GOLD
		2: return SILVER
		3: return BRONZE
	return Style.STONE_LIT
