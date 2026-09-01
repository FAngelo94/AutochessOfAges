class_name SettingsPanel
extends Panel

## Schermata "Impostazioni", raggiungibile dal menu principale. Per ora una sola
## voce: il volume degli effetti sonori. Struttura ricalcata su GuidePanel —
## backdrop a tutto schermo, colonna, pulsante Chiudi in fondo.

signal closed

var _volume_label: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	visible = false
	_build()


func open() -> void:
	visible = true


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
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)

	var title := Label.new()
	title.text = "IMPOSTAZIONI"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(title)

	column.add_child(_volume_card())

	var grow := Control.new()
	grow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(grow)

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 18, 6)
	close.pressed.connect(func() -> void:
		visible = false
		closed.emit())
	column.add_child(close)


func _volume_card() -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", Style.plate(Style.PLATE, Style.PLATE_DARK, 12, 4))

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 8)
	card.add_child(inner)

	var profile := get_node("/root/Profile")

	var header := HBoxContainer.new()
	inner.add_child(header)

	var name_label := Label.new()
	name_label.text = "Volume effetti"
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", Style.GOLD.darkened(0.15))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)

	_volume_label = Label.new()
	_volume_label.add_theme_font_size_override("font_size", 20)
	_volume_label.add_theme_color_override("font_color", Style.TEXT_DIM)
	header.add_child(_volume_label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = float(profile.sfx_volume)
	slider.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_volume_changed)
	# Rilasciando la maniglia, un click come anteprima del volume scelto.
	slider.drag_ended.connect(func(changed: bool) -> void:
		if changed:
			var sfx := get_node_or_null("/root/Sfx")
			if sfx != null:
				sfx.play("click"))
	inner.add_child(slider)

	_refresh_volume_label(float(profile.sfx_volume))
	return card


func _on_volume_changed(value: float) -> void:
	get_node("/root/Profile").set_sfx_volume(value)
	_refresh_volume_label(value)


func _refresh_volume_label(value: float) -> void:
	if _volume_label != null:
		_volume_label.text = "%d%%" % roundi(value * 100.0)
