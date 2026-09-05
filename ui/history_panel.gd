class_name HistoryPanel
extends Panel

## Cronologia delle partite giocate, dalla più recente.
##
## Unisce due sorgenti che non possono essere una sola: le partite online le
## possiede il server (`match_history` su Postgres, lette via HISTORY_REQUEST —
## il client non è mai autoritativo nemmeno sulla propria storia), quelle contro
## il computer stanno solo su questo dispositivo (app/match_log.gd). Da ospite o
## offline la lista non è vuota né in errore: mostra le locali e basta.
##
## Struttura presa da ui/collection_panel.gd — stesso `open()`, stesso segnale
## `closed`, stessa targa di chiusura in fondo — perché è la stessa gestualità:
## una schermata piena che copre il menu e si chiude tornando indietro.

signal closed

## Quante partite online chiedere al server. Il tetto vero lo impone il master
## (HISTORY_MAX): questo è quanto ne serve a una schermata da scorrere.
const REMOTE_LIMIT := 20

var _list: VBoxContainer
var _status: Label
var _rows: Array = []
var _requested := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	visible = false
	_build()


func open() -> void:
	visible = true
	_rows = MatchLog.local_matches()
	_refresh()
	_fetch_remote()


func _build() -> void:
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.text = "CRONOLOGIA"
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

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 18, 6)
	close.pressed.connect(func() -> void:
		visible = false
		closed.emit())
	column.add_child(close)


## Le partite online arrivano da una richiesta di rete: la lista locale è già a
## video quando parte, e si arricchisce quando la risposta torna. Una sola
## richiesta per apertura del pannello.
func _fetch_remote() -> void:
	var auth := get_node_or_null("/root/Auth")
	if auth == null or not auth.has_method("request_history") or not auth.is_logged_in():
		return
	if _requested:
		return
	_requested = true
	_status.text = "Carico le partite online…"
	auth.request_history(REMOTE_LIMIT, func(ok: bool, matches: Array) -> void:
		_requested = false
		if not ok:
			_status.text = "Partite online non raggiungibili: qui sotto solo quelle locali."
			return
		for entry in matches:
			if typeof(entry) == TYPE_DICTIONARY:
				var row: Dictionary = (entry as Dictionary).duplicate()
				row["mode"] = "online"
				_rows.append(row)
		_refresh())


func _refresh() -> void:
	for child in _list.get_children():
		child.queue_free()

	_rows.sort_custom(func(a, b): return String(a.get("ended_at", "")) > String(b.get("ended_at", "")))

	if _rows.is_empty():
		_status.text = "Nessuna partita ancora. Giocane una e la ritrovi qui."
		return
	if not _requested:
		_status.text = "%d partite" % _rows.size()

	for row in _rows:
		_list.add_child(_match_row(row))


func _match_row(row: Dictionary) -> Control:
	var placement := int(row.get("placement", 0))

	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel",
		Style.box(Style.PLATE_DARK, _placement_color(placement), 2, 10))

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
	badge.text = "%d°" % placement if placement > 0 else "—"
	badge.custom_minimum_size = Vector2(58, 0)
	badge.add_theme_font_size_override("font_size", 30)
	badge.add_theme_color_override("font_color", _placement_color(placement))
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(badge)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 2)
	line.add_child(column)

	var head := Label.new()
	head.text = "%s · %s" % [_mode_label(row), _hero_label(String(row.get("hero_id", "")))]
	head.add_theme_font_size_override("font_size", 20)
	column.add_child(head)

	var detail := Label.new()
	detail.text = _detail_text(row)
	detail.add_theme_font_size_override("font_size", 16)
	detail.add_theme_color_override("font_color", Style.TEXT_DIM)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(detail)

	var delta := int(row.get("mmr_delta", 0))
	if delta != 0:
		var mmr := Label.new()
		mmr.text = "%s%d" % ["+" if delta > 0 else "", delta]
		mmr.add_theme_font_size_override("font_size", 22)
		mmr.add_theme_color_override("font_color", Style.GOLD if delta > 0 else Style.TEXT_DIM)
		mmr.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line.add_child(mmr)

	return frame


## Il primo posto è oro, il resto sfuma: il colore dice l'esito prima del testo.
func _placement_color(placement: int) -> Color:
	if placement == 1:
		return Style.GOLD
	if placement > 0 and placement <= 4:
		return Style.BLUE
	return Style.STONE_LIT


func _mode_label(row: Dictionary) -> String:
	if String(row.get("mode", "")) != "online":
		return "vs computer"
	return "classificata" if bool(row.get("ranked", false)) else "amichevole"


func _hero_label(hero_id: String) -> String:
	if hero_id == "" or not GameData.has_hero(hero_id):
		return "eroe ignoto"
	return GameData.hero(hero_id).display_name


## Seconda riga: data, unità finali, vita rimasta. Le unità arrivano già pronte
## dal server (RPC player_match_history) o dalla telemetria locale.
func _detail_text(row: Dictionary) -> String:
	var bits: Array = []
	var when := String(row.get("ended_at", ""))
	if when != "":
		bits.append(when.replace("T", " ").left(16))
	var units := _unit_names(row.get("units", []))
	if units != "":
		bits.append(units)
	if int(row.get("hp", 0)) > 0:
		bits.append("%d vita" % int(row["hp"]))
	return "  ·  ".join(bits)


func _unit_names(units: Variant) -> String:
	if typeof(units) != TYPE_ARRAY:
		return ""
	var names: Array = []
	for entry in units:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var unit_id := String(entry.get("unit_id", ""))
		if not GameData.has_unit(unit_id):
			continue
		var star := int(entry.get("final_star", 1))
		names.append(GameData.unit(unit_id).display_name + ("★".repeat(star) if star > 1 else ""))
	return ", ".join(names)
