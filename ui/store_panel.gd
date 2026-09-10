class_name StorePanel
extends Panel

## Crowdfunding Store: il negozio non vende contenuti, raccoglie donazioni.
##
## Parla solo con l'autoload Store, che a sua volta nasconde quale negozio ci
## sia davvero sotto (Google Play, Web Billing, o quello finto in sviluppo).
## Se nessun negozio è disponibile il pannello lo dice e non offre pulsanti che
## non funzionerebbero: un pagamento che non parte è peggio di un pagamento che
## non viene proposto.
##
## Due cose che la schermata deve dire e non nascondere:
##
##   * Gli importi sono FISSI, uno per pulsante. Non e' una scelta di UI: su
##     Google Play il prezzo di un prodotto e' fisso e una cifra arbitraria non
##     sarebbe addebitabile, quindi un campo libero prometterebbe qualcosa che
##     il pagamento non puo' mantenere. Aggiungere un importo = un taglio in
##     data/catalog.json + un prodotto nelle dashboard.
##   * Donare senza account renderebbe la donazione non attribuibile, quindi da
##     ospiti si invita ad accedere invece di aprire un pagamento che poi non
##     comparirebbe nella propria cronologia.

signal closed

## La barra è pubblica: il totale arriva dal server, che lo somma dalle righe
## scritte dal webhook di RevenueCat. Solo col negozio finto, in sviluppo, si
## ripiega sul totale locale — altrimenti la barra resterebbe a zero e non si
## potrebbe provare niente.
const MINE_LIMIT := 20

var _status: Label
var _bar: ProgressBar
var _bar_label: Label
## amount_cents -> Button, un pulsante per taglio donabile.
var _quick: Dictionary = {}

var _total_cents := 0
var _total_known := false

## L'autoload si recupera dall'albero anziché usare il nome globale "Store":
## quando gli script vengono compilati da riga di comando (test headless) gli
## autoload non sono ancora registrati come identificatori.
var _store: Node
var _auth: Node


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	visible = false
	_store = get_node("/root/Store")
	_auth = get_node_or_null("/root/Auth")
	_build()

	_store.products_loaded.connect(func(_products: Dictionary) -> void: _refresh())
	_store.donation_completed.connect(_on_donation_completed)


func open() -> void:
	visible = true
	_refresh()
	_request_total()


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
	title.text = "CROWDFUNDING STORE"
	title.add_theme_font_size_override("font_size", 30)
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

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	scroll.add_child(body)

	for row in _build_tier_rows():
		body.add_child(row)

	body.add_child(_build_progress())
	body.add_child(_build_goals())

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 18, 6)
	close.pressed.connect(func() -> void:
		visible = false
		closed.emit())
	column.add_child(close)


## I tagli, tre per riga. L'importo È il pulsante: donare è un gesto singolo e
## non ha niente da leggere prima.
##
## Tre per riga e non di più: su 720 px di larghezza, tolti i margini, restano
## ~215 px a pulsante — abbastanza per "0,50 €" e per il minimo tattile in
## altezza. Una quarta colonna li stringerebbe sotto la soglia in cui si sbaglia
## a premere.
const TIERS_PER_ROW := 3


func _build_tier_rows() -> Array[Control]:
	var rows: Array[Control] = []
	var current: HBoxContainer = null
	var index := 0
	for amount in Catalog.donation_tiers():
		if index % TIERS_PER_ROW == 0:
			current = HBoxContainer.new()
			current.add_theme_constant_override("separation", 10)
			rows.append(current)
		current.add_child(_build_tier_button(int(amount)))
		index += 1
	return rows


func _build_tier_button(amount_cents: int) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	# I pulsanti di una riga si dividono la larghezza in parti uguali: importi
	# diversi non devono dare pulsanti di dimensioni diverse, o il più largo
	# sembra il consigliato.
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 24)
	button.add_theme_color_override("font_color", Style.INK)
	button.add_theme_color_override("font_hover_color", Style.INK)
	button.add_theme_color_override("font_pressed_color", Style.INK)
	Style.apply_plate(button, Style.GOLD, Style.GOLD_DEEP, 18, 6)
	button.pressed.connect(func() -> void: _donate(amount_cents))
	_quick[amount_cents] = button
	return button


func _build_progress() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	_bar = ProgressBar.new()
	_bar.min_value = 0
	_bar.max_value = maxi(Catalog.donation_goal_cents(), 1)
	_bar.value = 0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 26)
	_bar.add_theme_stylebox_override("background", Style.box(Style.PLATE_DARK, Style.PLATE, 1, 8))
	_bar.add_theme_stylebox_override("fill", Style.box(Style.GOLD, Style.GOLD_DEEP, 1, 8))
	box.add_child(_bar)

	_bar_label = Label.new()
	_bar_label.add_theme_font_size_override("font_size", 20)
	_bar_label.add_theme_color_override("font_color", Style.TEXT_DIM)
	box.add_child(_bar_label)

	return box


func _build_goals() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var heading := Label.new()
	heading.text = "Al raggiungimento della cifra:"
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	heading.add_theme_font_size_override("font_size", 22)
	heading.add_theme_color_override("font_color", Style.GOLD)
	box.add_child(heading)

	for goal in Catalog.donation_goals():
		var line := Label.new()
		line.text = "• %s" % goal
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.add_theme_font_size_override("font_size", 19)
		line.add_theme_color_override("font_color", Style.TEXT_DIM)
		box.add_child(line)

	return box


# --------------------------------------------------------------------------
# Stato
# --------------------------------------------------------------------------

func _can_donate() -> bool:
	var available: bool = _store.backend.is_available() or _store.backend is MockStore
	return available and _is_logged_in()


func _is_logged_in() -> bool:
	return _auth != null and _auth.is_logged_in()


func _donate(amount_cents: int) -> void:
	if not _can_donate() or amount_cents <= 0:
		return
	_status.text = "Tributo di %s in corso…" % _euro(amount_cents)
	_store.donate(amount_cents)


## `keep_status` conserva il messaggio di esito di un tributo appena concluso.
##
## Senza, l'esito durava una frazione di secondo: _on_donation_completed
## scriveva "Grazie, benefattore!" e poi chiamava _refresh(), che rimetteva
## subito il messaggio generico. Il fallimento sembrava funzionare solo perche'
## ha anche una modale, che resta; il successo spariva prima di essere letto, e
## dava l'impressione che premere il pulsante non facesse niente.
func _refresh(keep_status := false) -> void:
	var available: bool = _store.backend.is_available() or _store.backend is MockStore
	if not keep_status:
		if not available:
			_status.text = "Pagamenti non disponibili su questa piattaforma. Tutti i contenuti di gioco restano accessibili."
		elif not _is_logged_in():
			_status.text = "Accedi con un account per lasciare un tributo: serve ad attribuirtelo."
		else:
			_status.text = "Ogni tributo sostiene lo sviluppo del gioco."

	for amount in _quick:
		var button: Button = _quick[amount]
		button.text = _price_label(int(amount))
		button.disabled = not _can_donate()

	_refresh_bar()


## Il prezzo localizzato dallo store quando c'è; altrimenti la cifra del
## catalogo, che è comunque quella che verrà addebitata.
func _price_label(amount_cents: int) -> String:
	var price: String = _store.donation_price(amount_cents)
	return price if price != "—" else _euro(amount_cents)


func _refresh_bar() -> void:
	var goal := Catalog.donation_goal_cents()
	_bar.max_value = maxi(goal, 1)
	_bar.value = clampi(_total_cents, 0, goal)
	if _total_known:
		_bar_label.text = "%s su %s" % [_euro(_total_cents), _euro(goal)]
	else:
		_bar_label.text = "— su %s" % _euro(goal)


## Chiede il totale al server. Da ospiti o offline non c'è nessuno a cui
## chiederlo: col negozio finto si mostra il totale locale (è l'unico modo di
## vedere la barra muoversi in sviluppo), altrimenti si resta sul trattino
## invece di mostrare uno zero che sembrerebbe un dato vero.
func _request_total() -> void:
	if _store.backend is MockStore:
		_total_cents = _store.local_donation_total_cents()
		_total_known = true
		_refresh_bar()
		return
	if _auth == null or not _auth.is_logged_in():
		_total_known = false
		_refresh_bar()
		return
	_auth.request_donations(MINE_LIMIT, func(ok: bool, data: Dictionary) -> void:
		if not ok:
			_total_known = false
			_refresh_bar()
			return
		_total_cents = int(data.get("total_cents", 0))
		_total_known = true
		_refresh_bar())


func _on_donation_completed(amount_cents: int, success: bool, reason: String) -> void:
	if success:
		_status.text = "Grazie, benefattore! Il tuo tributo di %s è stato accolto." % _euro(amount_cents)
		# La riga la scrive il webhook di RevenueCat, che arriva in pochi
		# secondi: il totale si richiede subito e poi ancora una volta, invece
		# di inventare uno stato "in attesa" da riconciliare.
		_request_total()
		get_tree().create_timer(3.0).timeout.connect(_request_total)
	elif reason == "cancelled":
		# L'utente ha cambiato idea: non è un errore e non va presentato come tale.
		_status.text = "Tributo annullato."
	else:
		var detail := reason if reason != "" else "errore sconosciuto"
		# Il motivo grezzo dell'SDK resta QUI e non nella modale: e' in inglese,
		# in gergo, e a chi ha appena visto fallire un pagamento non dice niente.
		# Nella riga di stato serve a chi sviluppa; nella modale sarebbe rumore.
		_status.text = "Tributo non riuscito: %s" % detail
		# Un fallimento vero (non un ripensamento) ferma l'utente: la riga di
		# stato da sola passa inosservata, e chi resta col dubbio di essere
		# stato addebitato riprova.
		#
		# L'ambientazione si ferma al titolo: la frase sull'addebito e' in
		# italiano piano, perche' e' la prima domanda di chi vede fallire un
		# pagamento e non deve costargli un secondo di interpretazione.
		ModalDialog.notice(self, "Il tributo non è giunto a destinazione",
			"Non ti è stato addebitato nulla.\n\n"
			+ "Il pagamento non è andato a buon fine. Puoi riprovare quando vuoi.")
	# keep_status: l'esito appena scritto non va sovrascritto dal messaggio
	# generico, o sparisce prima che qualcuno riesca a leggerlo.
	_refresh(true)


static func _euro(cents: int) -> String:
	if cents % 100 == 0:
		return "%d €" % (cents / 100)
	return "%d,%02d €" % [cents / 100, cents % 100]
