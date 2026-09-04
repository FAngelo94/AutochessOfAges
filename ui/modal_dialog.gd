class_name ModalDialog
extends CanvasLayer

## Finestra di dialogo del gioco, al posto degli AcceptDialog/ConfirmationDialog
## di serie: quelli aprono una finestrella di sistema, con i colori del sistema
## operativo invece che quelli della pietra e dell'oro, e soprattutto lasciano
## la scena sotto perfettamente cliccabile — niente dice al giocatore che deve
## rispondere prima di poter fare altro.
##
## Vive su un CanvasLayer proprio, così sta sopra qualunque cosa la scena
## ospite stia disegnando (plancia, pannelli, barra di fase) senza dipendere
## dall'ordine dei figli né dagli z-index di chi la apre.
##
## Si apre dalle due funzioni statiche, che la costruiscono, l'appendono
## all'albero e la mostrano:
##
##     ModalDialog.notice(self, "Titolo", "Testo")                 # un solo tasto
##     ModalDialog.confirm(self, "Titolo", "Testo", "Esci")         # conferma + annulla
##
## e si ascoltano `confirmed` / `cancelled`. Si libera da sola alla chiusura:
## chi la apre non deve conservarne il riferimento.

signal confirmed
signal cancelled

## Sopra ogni altro strato dell'interfaccia di gioco.
const LAYER := 128

## Il velo non è nero pieno: la scena sotto resta riconoscibile — si capisce di
## essere *sopra* qualcosa, non di aver cambiato schermata — ma abbastanza
## spenta da spostare l'attenzione sul riquadro.
const VEIL := Color(0.04, 0.04, 0.07, 0.72)

## Testo del corpo: più tenue dell'oro del titolo, ma non grigio come i
## sottotitoli, altrimenti la frase che spiega il problema si legge male.
const BODY := Color(0.88, 0.88, 0.93)

## Larghezza massima del riquadro. Oltre, le righe diventano troppo lunghe da
## seguire; sotto, ci si adatta allo schermo lasciando un margine ai lati.
const MAX_WIDTH := 560.0
const SIDE_MARGIN := 28.0

var _title_text := ""
var _message_text := ""
var _ok_text := ""
var _cancel_text := ""
var _answered := false


## Avviso: un solo tasto, nessuna scelta da fare. Emette comunque `confirmed`
## alla chiusura, per chi voglia incatenarci qualcosa.
static func notice(host: Node, title: String, message: String,
		ok_text: String = "Ho capito") -> ModalDialog:
	return _open(host, title, message, ok_text, "")


## Domanda: due tasti. `ok_text` è il verbo dell'azione ("Esci", "Abbandona"),
## non un "OK" generico — su un tasto che distrugge una partita in corso il
## giocatore deve leggere cosa sta per succedere.
static func confirm(host: Node, title: String, message: String, ok_text: String,
		cancel_text: String = "Annulla") -> ModalDialog:
	return _open(host, title, message, ok_text, cancel_text)


static func _open(host: Node, title: String, message: String, ok_text: String,
		cancel_text: String) -> ModalDialog:
	var dialog := ModalDialog.new()
	dialog._title_text = title
	dialog._message_text = message
	dialog._ok_text = ok_text
	dialog._cancel_text = cancel_text
	host.add_child(dialog)
	return dialog


func _ready() -> void:
	layer = LAYER
	# La modale resta viva e reattiva anche se chi la apre mette in pausa
	# l'albero (la conferma d'uscita arriva a partita ferma).
	process_mode = Node.PROCESS_MODE_ALWAYS

	_build()


func _build() -> void:
	# Velo: oscura la scena e — la parte che conta — intercetta ogni click con
	# MOUSE_FILTER_STOP, così i pulsanti sotto non rispondono più finché la
	# modale è aperta. È questo, non il colore, a rendere la finestra modale.
	var veil := ColorRect.new()
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.color = VEIL
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(veil)

	# CenterContainer: il riquadro sta al centro dello schermo qualunque sia la
	# risoluzione, senza calcoli di offset che sbagliano al ridimensionamento.
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		Style.plate(Style.STONE.darkened(0.34), Style.GOLD_DEEP, 22, 8))
	centre.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 26)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	margin.add_child(column)

	var title := Label.new()
	title.text = _title_text.to_upper()
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Style.GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	# Filo d'oro sotto il titolo: separa senza aggiungere un altro riquadro.
	var rule := ColorRect.new()
	rule.color = Style.GOLD_DEEP
	rule.custom_minimum_size = Vector2(0, 2)
	column.add_child(rule)

	var message := Label.new()
	message.text = _message_text
	message.add_theme_font_size_override("font_size", 19)
	message.add_theme_color_override("font_color", BODY)
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.custom_minimum_size = Vector2(_body_width(), 0)
	column.add_child(message)

	column.add_child(_buttons())

	_animate_in(panel)


## Larghezza del testo: il massimo leggibile, ristretto allo schermo quando è
## più stretto di così (finestre piccole, ritratto su telefono).
func _body_width() -> float:
	var available := get_viewport().get_visible_rect().size.x - SIDE_MARGIN * 2.0
	return maxf(240.0, minf(MAX_WIDTH, available))


## Un tasto solo per gli avvisi, due per le domande. L'annulla sta a sinistra e
## resta in tinta neutra: quello colorato d'oro è sempre l'azione, così il
## pollice non impara a premere a caso.
func _buttons() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	if _cancel_text != "":
		var cancel := Button.new()
		cancel.text = _cancel_text
		cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cancel.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
		cancel.add_theme_font_size_override("font_size", 20)
		Style.apply_plate(cancel, Style.PLATE, Style.PLATE_DARK, 14, 4)
		cancel.pressed.connect(_on_cancel)
		row.add_child(cancel)

	var ok := Button.new()
	ok.text = _ok_text
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	ok.add_theme_font_size_override("font_size", 20)
	ok.add_theme_color_override("font_color", Style.INK)
	Style.apply_plate(ok, Style.GOLD, Style.GOLD_DEEP, 14, 4)
	ok.pressed.connect(_on_confirm)
	row.add_child(ok)

	return row


## Comparsa breve: il riquadro sale di scala e sfuma dentro. Serve a far
## capire che è arrivato *sopra* la schermata, invece di apparire di colpo come
## se la scena fosse cambiata.
func _animate_in(panel: Control) -> void:
	panel.pivot_offset = panel.size / 2.0
	panel.scale = Vector2(0.92, 0.92)
	panel.modulate.a = 0.0
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(panel, "scale", Vector2.ONE, 0.14) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(panel, "modulate:a", 1.0, 0.12)


## Il tasto "indietro" di sistema (e Esc su desktop) equivale ad annullare: una
## modale senza via d'uscita da tastiera è una trappola.
func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_cancel()


func _on_confirm() -> void:
	_close(true)


func _on_cancel() -> void:
	_close(false)


## `_answered` protegge dal doppio scatto: due tocchi rapidi sullo stesso tasto
## emetterebbero altrimenti il segnale due volte, e "Abbandona" partirebbe due
## volte su una partita che nel frattempo è già stata lasciata.
func _close(accepted: bool) -> void:
	if _answered:
		return
	_answered = true
	if accepted:
		confirmed.emit()
	else:
		cancelled.emit()
	queue_free()
