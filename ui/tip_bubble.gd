class_name TipBubble
extends MarginContainer

## Suggerimenti one-shot in partita: una bolla inserita nel flusso del layout,
## tra lo scroll di preparazione e la barra dei comandi — non un overlay
## ancorato in assoluto, altrimenti coprirebbe COMBATTI invece di spingerlo
## in basso. Compare la prima volta che il giocatore incontra un meccanismo e
## non ricompare più (stato in Profile.seen_tips).
##
## extends MarginContainer (non Control): un Container calcola da sé la
## propria dimensione minima a partire dai figli visibili e la comunica al
## VBoxContainer che lo ospita, cosa che un Control semplice non farebbe —
## è quello che permette alla bolla di "spingere" il resto quando compare e
## di sparire senza lasciare uno spazio vuoto quando non c'è nulla da mostrare.

## Ogni id qui dentro deve avere una voce corrispondente in
## data/tutorial.json sotto "tips" — tests/run_tests.gd lo verifica.
const KNOWN_TIPS := ["shop", "bench", "board", "star", "synergy", "combat", "economy"]

## Spento dai test per non interferire col percorso già coperto da ui_smoke.
var enabled: bool = true

var _queue: Array[String] = []
var _panel: PanelContainer
var _title: Label
var _body: Label
var _profile: Node


func _ready() -> void:
	_profile = get_node("/root/Profile")
	add_theme_constant_override("margin_left", 0)
	add_theme_constant_override("margin_right", 0)
	add_theme_constant_override("margin_top", 0)
	add_theme_constant_override("margin_bottom", 0)
	_build()


func queue_tip(tip_id: String) -> void:
	if not enabled:
		return
	if _profile.has_seen_tip(tip_id):
		return
	if tip_id in _queue:
		return
	if GameData.tip(tip_id).is_empty():
		push_error("TipBubble: suggerimento sconosciuto '%s'" % tip_id)
		return
	_queue.append(tip_id)
	if not _panel.visible:
		_show_next()


func is_showing() -> bool:
	return _panel.visible


func dismiss() -> void:
	if not _panel.visible:
		return
	var current := _queue.pop_front() as String
	_profile.mark_tip_seen(current)
	_show_next()


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.add_theme_stylebox_override("panel", Style.plate(Style.PLATE, Style.GOLD_DEEP, 16, 5))
	add_child(_panel)

	var inner_margin := MarginContainer.new()
	inner_margin.add_theme_constant_override("margin_left", 4)
	inner_margin.add_theme_constant_override("margin_right", 4)
	inner_margin.add_theme_constant_override("margin_top", 4)
	inner_margin.add_theme_constant_override("margin_bottom", 4)
	_panel.add_child(inner_margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	inner_margin.add_child(column)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 20)
	_title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(_title)

	_body = Label.new()
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_theme_font_size_override("font_size", 17)
	column.add_child(_body)

	var dismiss_button := Button.new()
	dismiss_button.text = "Ho capito"
	dismiss_button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	dismiss_button.add_theme_font_size_override("font_size", 18)
	Style.apply_plate(dismiss_button, Style.BLUE, Style.BLUE_DEEP, 14, 4)
	dismiss_button.pressed.connect(dismiss)
	column.add_child(dismiss_button)


func _show_next() -> void:
	if _queue.is_empty():
		_panel.visible = false
		return
	var entry := GameData.tip(_queue[0])
	_title.text = String(entry.get("title", ""))
	_body.text = TutorialText.expand(String(entry.get("body", "")))
	_panel.visible = true
