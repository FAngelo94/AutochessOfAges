extends Control

## Sala d'attesa online (MULTIPLAYER_PLAN.md M6).
##
## Convenzione del progetto: il .tscn e' uno stub, tutta la UI si costruisce qui
## in _build(). Si connette al master tramite una RemoteSession, entra in coda,
## mostra "giocatori in coda: N/8" e il conto alla rovescia, e al MATCH_ASSIGNED
## passa a ui/main.tscn con la sessione gia' agganciata al worker.
##
## Il passaggio della sessione a ui/main.gd usa un meta sulla radice
## ("pending_session"): stesso spirito con cui il menu passa l'eroe scelto
## tramite Profile — nessun autoload nuovo, e il meta viene consumato subito.

const MENU_SCENE := "res://ui/menu.tscn"
const GAME_SCENE := "res://ui/main.tscn"
const SESSION_META := "pending_session"

var _profile: Node
var _session: RemoteSession

var _status_label: Label
var _count_label: Label
var _timer_label: Label
var _cancel_button: Button


func _ready() -> void:
	GameData.ensure_loaded()
	_profile = get_node("/root/Profile")
	_build()

	var auth := get_node_or_null("/root/Auth")
	if not DevNet.enabled() and (auth == null or not auth.is_logged_in()):
		# Difensivo: in lobby non ci si arriva da sloggati.
		get_tree().change_scene_to_file(MENU_SCENE)
		return

	_session = RemoteSession.new()
	_session.drive(self)
	_session.queue_welcome.connect(_on_welcome)
	_session.queue_updated.connect(_on_queue_updated)
	_session.queue_rejected.connect(_on_rejected)
	_session.not_configured.connect(_on_not_configured)
	_session.connection_lost.connect(_on_connection_lost)
	_session.match_assigned.connect(_on_match_assigned)
	_session.start_queue(_profile.effective_hero())


# --------------------------------------------------------------------------

func _build() -> void:
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_top", 48)
	margin.add_theme_constant_override("margin_bottom", 32)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(column)

	var title := Label.new()
	title.text = "SALA D'ATTESA"
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", Style.GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	_status_label = Label.new()
	_status_label.text = "Connessione al server…"
	_status_label.add_theme_font_size_override("font_size", 20)
	_status_label.add_theme_color_override("font_color", Style.TEXT_DIM)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_status_label)

	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", Style.plate(Style.STONE.darkened(0.3), Style.GOLD_DEEP, 18, 6))
	column.add_child(plate)

	var plate_col := VBoxContainer.new()
	plate_col.add_theme_constant_override("separation", 10)
	plate.add_child(plate_col)

	_count_label = Label.new()
	_count_label.text = "Giocatori in coda: 0/%d" % RemoteSession.MAX_QUEUE_SLOTS
	_count_label.add_theme_font_size_override("font_size", 24)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate_col.add_child(_count_label)

	_timer_label = Label.new()
	_timer_label.text = "In attesa di altri giocatori…"
	_timer_label.add_theme_font_size_override("font_size", 20)
	_timer_label.add_theme_color_override("font_color", Style.TEXT_DIM)
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate_col.add_child(_timer_label)

	_cancel_button = Button.new()
	_cancel_button.text = "Annulla"
	_cancel_button.custom_minimum_size = Vector2(0, Style.TOUCH_PRIMARY)
	_cancel_button.add_theme_font_size_override("font_size", 26)
	Style.apply_plate(_cancel_button, Style.BLUE, Style.BLUE_DEEP, 20, 8)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	column.add_child(_cancel_button)


# --------------------------------------------------------------------------
# Segnali della sessione
# --------------------------------------------------------------------------

func _on_welcome(username: String) -> void:
	if username != "":
		_status_label.text = "In coda come %s" % username
	else:
		_status_label.text = "In coda"


func _on_queue_updated(players: int, seconds_left: int) -> void:
	_count_label.text = "Giocatori in coda: %d/%d" % [players, RemoteSession.MAX_QUEUE_SLOTS]
	if seconds_left > 0:
		_timer_label.text = "La partita inizia tra %d s" % seconds_left
	else:
		_timer_label.text = "Avvio della partita…"


func _on_match_assigned() -> void:
	_status_label.text = "Partita trovata!"
	_cancel_button.disabled = true
	# La sessione e' gia' agganciata al worker: la si consegna a ui/main.gd.
	get_tree().root.set_meta(SESSION_META, _session)
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_rejected(reason: String) -> void:
	_fail("Accesso rifiutato dal server (%s)." % _reason_text(reason))


func _on_not_configured() -> void:
	_fail("La modalità online non è ancora configurata su questo dispositivo.")


func _on_connection_lost(reason: String) -> void:
	if reason == "not configured":
		return  # gia' gestito da not_configured
	_fail("Impossibile raggiungere il server. Riprova più tardi.")


## Fine corsa: qualcosa è andato storto e la sala d'attesa non è più un'attesa.
## Una modale lo dice a chiare lettere e l'unica uscita — anche col tasto
## indietro — è il menu.
func _fail(message: String) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", Color(0.92, 0.5, 0.45))
	_count_label.text = ""
	_timer_label.text = ""
	_cancel_button.visible = false
	var dialog := ModalDialog.notice(self, "Partita non avviata", message)
	dialog.confirmed.connect(_return_to_menu)
	dialog.cancelled.connect(_return_to_menu)


func _reason_text(reason: String) -> String:
	match reason:
		"version": return "aggiorna il gioco"
		"auth": return "sessione non valida"
		"banned": return "account sospeso"
		_: return reason


# --------------------------------------------------------------------------

func _on_cancel_pressed() -> void:
	if _session != null:
		_session.leave_queue()
	_return_to_menu()


func _return_to_menu() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)
