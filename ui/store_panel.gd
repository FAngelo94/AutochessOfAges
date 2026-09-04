class_name StorePanel
extends Panel

## Schermata degli acquisti.
##
## Parla solo con l'autoload Store, che a sua volta nasconde quale negozio ci
## sia davvero sotto (Google Play, Web Billing, o quello finto in sviluppo).
## Se nessun negozio è disponibile il pannello lo dice e non offre pulsanti
## che non funzionerebbero: un acquisto che non parte è peggio di un acquisto
## che non viene proposto.

signal closed

var _list: VBoxContainer
var _status: Label
var _rows: Dictionary = {}

## L'autoload si recupera dall'albero anziché usare il nome globale "Store":
## quando gli script vengono compilati da riga di comando (test headless) gli
## autoload non sono ancora registrati come identificatori.
var _store: Node


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	visible = false
	_store = get_node("/root/Store")
	_build()

	_store.entitlements_changed.connect(_refresh)
	_store.products_loaded.connect(func(_products: Dictionary) -> void: _refresh())
	_store.purchase_completed.connect(_on_purchase_completed)


func open() -> void:
	visible = true
	_refresh()


func _build() -> void:
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.text = "NEGOZIO"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(title)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 18)
	_status.add_theme_color_override("font_color", Style.TEXT_DIM)
	column.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 12)
	scroll.add_child(_list)

	for entitlement_id in Catalog.entitlement_ids():
		_list.add_child(_build_row(entitlement_id))

	# Google Play richiede che il ripristino sia raggiungibile: senza, chi
	# reinstalla perde ciò che ha già pagato.
	var restore := Button.new()
	restore.text = "Ripristina acquisti"
	restore.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	restore.add_theme_font_size_override("font_size", 22)
	Style.apply_plate(restore, Style.PLATE, Style.PLATE_DARK, 18, 6)
	restore.pressed.connect(func() -> void:
		_store.restore_purchases()
		_status.text = "Ripristino in corso…")
	column.add_child(restore)

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 18, 6)
	close.pressed.connect(func() -> void:
		visible = false
		closed.emit())
	column.add_child(close)


## Ogni prodotto è una scheda in verticale: nome, descrizione, e sotto il
## pulsante largo quanto la scheda. Affiancare testo e prezzo — come si fa su
## desktop — su 720 px lascerebbe alla descrizione una colonna da 400 px e al
## prezzo una riga sola in cui non entra "Abbonamento mensile".
func _build_row(entitlement_id: String) -> Control:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", Style.plate(Style.PLATE_DARK, Style.PLATE, 18, 4))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	row.add_child(box)

	var name := Label.new()
	name.text = Catalog.entitlement_name(entitlement_id)
	name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name.add_theme_font_size_override("font_size", 26)
	name.add_theme_color_override("font_color", Style.GOLD)
	box.add_child(name)

	var description := Label.new()
	description.text = Catalog.entitlement_description(entitlement_id)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_font_size_override("font_size", 19)
	description.add_theme_color_override("font_color", Style.TEXT_DIM)
	box.add_child(description)

	var button := Button.new()
	button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	button.add_theme_font_size_override("font_size", 26)
	button.add_theme_color_override("font_color", Style.INK)
	button.add_theme_color_override("font_hover_color", Style.INK)
	button.add_theme_color_override("font_pressed_color", Style.INK)
	Style.apply_plate(button, Style.GOLD, Style.GOLD_DEEP, 18, 6)
	button.pressed.connect(func() -> void:
		_status.text = "Acquisto di %s in corso…" % Catalog.entitlement_name(entitlement_id)
		_store.purchase(entitlement_id))
	box.add_child(button)

	_rows[entitlement_id] = button
	return row


func _refresh() -> void:
	var available: bool = _store.backend.is_available() or _store.backend is MockStore
	_status.text = "Negozio: %s" % _store.backend.backend_name()
	if not available:
		_status.text += " — non disponibile su questa piattaforma. Tutti i contenuti di gioco restano accessibili."

	for entitlement_id in _rows:
		var button: Button = _rows[entitlement_id]
		if _store.has_entitlement(entitlement_id):
			button.text = "Attivo" if Catalog.is_subscription(entitlement_id) else "Posseduto"
			button.disabled = true
			# Un prodotto già tuo non è più un invito: perde l'oro e resta lì
			# solo come conferma.
			button.add_theme_color_override("font_color", Style.TEXT_DIM)
			Style.apply_plate(button, Style.PLATE, Style.PLATE_DARK, 18, 6)
		else:
			button.text = _store.price_of(entitlement_id)
			button.disabled = not available
			button.add_theme_color_override("font_color", Style.INK)
			Style.apply_plate(button, Style.GOLD, Style.GOLD_DEEP, 18, 6)


func _on_purchase_completed(entitlement_id: String, success: bool, reason: String) -> void:
	var name := Catalog.entitlement_name(entitlement_id)
	if success:
		_status.text = "%s sbloccato." % name
	elif reason == "cancelled":
		# L'utente ha cambiato idea: non è un errore e non va presentato come tale.
		_status.text = "Acquisto annullato."
	else:
		var detail := reason if reason != "" else "errore sconosciuto"
		_status.text = "Acquisto non riuscito: %s" % detail
		# Un fallimento vero (non un ripensamento) ferma l'utente: la riga di
		# stato da sola passa inosservata, e chi resta col dubbio di essere stato
		# addebitato riprova.
		ModalDialog.notice(self, "Acquisto non riuscito",
			"Non è stato possibile completare l'acquisto di %s (%s).\n\n" % [name, detail]
			+ "Non ti è stato addebitato nulla. Riprova più tardi.")
	_refresh()
