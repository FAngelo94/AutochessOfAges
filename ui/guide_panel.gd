class_name GuidePanel
extends Panel

## Schermata "come si gioca": i capitoli di data/tutorial.json, uno per
## pannello, in ordine. Statica — si costruisce una sola volta in _ready() e
## non cambia più — perché i capitoli non dipendono dallo stato di una
## partita, a differenza della collezione o del negozio.

signal closed

var _reset_tips_button: Button
var _reset_tips_label: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	visible = false
	_build()


func open() -> void:
	visible = true
	get_node("/root/Profile").mark_tip_seen("guide_opened")


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
	title.text = "GUIDA"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	var sections := VBoxContainer.new()
	sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sections.add_theme_constant_override("separation", 10)
	scroll.add_child(sections)

	for entry in GameData.guide_sections():
		sections.add_child(_chapter(entry as Dictionary))

	sections.add_child(_reset_tips_row())

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 18, 6)
	close.pressed.connect(func() -> void:
		visible = false
		closed.emit())
	column.add_child(close)


func _chapter(entry: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Style.plate(Style.PLATE, Style.PLATE_DARK, 12, 4))

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	panel.add_child(inner)

	var title := Label.new()
	title.text = String(entry.get("title", ""))
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Style.GOLD.darkened(0.15))
	inner.add_child(title)

	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.add_theme_font_size_override("normal_font_size", 18)
	body.text = TutorialText.expand(String(entry.get("body", "")))
	inner.add_child(body)

	return panel


## Voce di servizio in fondo alla guida: rimette in coda tutti i suggerimenti
## one-shot, per rivederli senza dover cancellare il profilo. Non è un
## capitolo del tutorial, quindi vive fuori dal ciclo su guide_sections().
func _reset_tips_row() -> Control:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 4)

	_reset_tips_button = Button.new()
	_reset_tips_button.text = "Rivedi i suggerimenti"
	_reset_tips_button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	_reset_tips_button.add_theme_font_size_override("font_size", 18)
	Style.apply_plate(_reset_tips_button, Style.PLATE, Style.PLATE_DARK, 16, 5)
	_reset_tips_button.pressed.connect(_on_reset_tips_pressed)
	card.add_child(_reset_tips_button)

	_reset_tips_label = Label.new()
	_reset_tips_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_reset_tips_label.add_theme_font_size_override("font_size", 14)
	_reset_tips_label.add_theme_color_override("font_color", Style.TEXT_DIM)
	card.add_child(_reset_tips_label)

	return card


func _on_reset_tips_pressed() -> void:
	get_node("/root/Profile").reset_tips()
	_reset_tips_label.text = "I suggerimenti torneranno dalla prossima partita."
