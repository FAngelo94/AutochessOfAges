extends Control

## Schermata di accesso. È la nuova scena principale (project.godot): da qui si
## arriva alla home solo dopo essersi identificati — Google, email e password,
## o come ospite (offline, niente multiplayer né statistiche).
##
## Tre stati che ricostruiscono solo la colonna centrale: RESTORING mentre
## Auth.try_restore_session() è in volo, LOGIN e SIGNUP per le credenziali.
## Con backend non configurato, sessione già valida o scelta ospite già fatta,
## _ready() salta dritto al menu: è l'invariante "il gioco offline funziona
## senza account" (tests/auth_smoke.gd).
##
## Stesse convenzioni visive di ui/menu.gd: stesso fondale, stessa cornice
## (ui/castle_backdrop.gd), stessi margini — è la stessa stanza.

const MENU_SCENE := "res://ui/menu.tscn"
const GAME_SCENE := "res://ui/main.tscn"
## Stesso meta con cui ui/lobby.gd consegna una RemoteSession gia' agganciata:
## ui/main.gd._make_session() lo consuma cosi', a prescindere da chi l'ha messo.
const SESSION_META := "pending_session"

enum State { RESTORING, LOGIN, SIGNUP }

## Le chiavi restano ferme (arrivano dal server/da net/auth.gd), i testi si
## risolvono a runtime così seguono il locale corrente.
const REASON_KEYS := {
	"email_taken": "LOGIN_REASON_EMAIL_TAKEN",
	"invalid_credentials": "LOGIN_REASON_INVALID_CREDENTIALS",
	"invalid": "LOGIN_REASON_INVALID",
	"rate_limited": "LOGIN_REASON_RATE_LIMITED",
	"db": "LOGIN_REASON_DB",
	"google": "LOGIN_REASON_GOOGLE",
	"expired": "LOGIN_REASON_EXPIRED",
	"denied": "LOGIN_REASON_DENIED",
}

## Alzata da chi apre questa schermata di proposito pur essendo già ospite —
## le impostazioni, con "Accedi". Senza, _ready() rimbalzerebbe al menu per via
## di is_guest() e il pulsante sembrerebbe non fare nulla. Si consuma alla
## prima lettura: un ritorno successivo torna a saltare il login come prima.
static var force_prompt := false

var _auth: Node
var _state: int = State.LOGIN

var _column: VBoxContainer
var _error_label: Label
var _busy := false

# Campi dello stato corrente (ricreati a ogni _set_state).
var _email_edit: LineEdit
var _password_edit: LineEdit
var _confirm_edit: LineEdit
var _username_edit: LineEdit
var _primary_button: Button
var _primary_text := ""
var _google_button: Button
var _google_waiting := false
var _guest_button: Button


func _ready() -> void:
	# Prima di costruire qualunque testo: se il giocatore ha già scelto una
	# lingua, va applicata subito, non solo dal pannello impostazioni.
	get_node("/root/Profile").apply_locale()
	_auth = get_node_or_null("/root/Auth")
	var music := get_node_or_null("/root/Music")
	if music != null:
		music.play_general()
	# Il gioco e' stato chiuso a meta' di una partita online: si rientra
	# direttamente, prima di qualunque schermata di login (net/remote_session.gd
	# ha gia' tutto il necessario per riagganciarsi al worker da solo).
	if _try_resume_pending_match():
		return
	# Backend segnaposto (test headless, sviluppo locale), sessione già valida o
	# scelta "ospite" già fatta: non c'è niente da chiedere.
	var forced := force_prompt
	force_prompt = false
	if _auth == null or not _auth.is_configured() \
			or (not forced and (_auth.is_logged_in() or _auth.is_guest())):
		_go_to_menu()
		return
	_auth.login_completed.connect(_on_login_completed)
	_auth.session_restore_finished.connect(_on_restore_finished)
	_build()
	_set_state(State.RESTORING if _auth.restore_pending() else State.LOGIN)


## Differito: _go_to_menu() può essere chiamata da _ready(), quando l'albero
## sta ancora aggiungendo figli e cambiare scena solleva "Parent node is busy".
func _go_to_menu() -> void:
	get_tree().change_scene_to_file.call_deferred(MENU_SCENE)


## true se c'era una partita in sospeso e il tentativo di rientro e' partito
## (call_deferred, stesso motivo di _go_to_menu()). Un match_token scaduto o
## un match gia' concluso non falliscono qui: arrivano come COMMAND_REJECTED
## o connessione impossibile una volta dentro ui/main.gd, gestiti come una
## riconnessione fallita qualunque (schermata di connessione persa).
func _try_resume_pending_match() -> bool:
	if not RemoteSession.has_pending_match():
		return false
	var session := RemoteSession.new()
	session.drive(self)
	if not session.resume_from_pending():
		return false
	get_tree().root.set_meta(SESSION_META, session)
	get_tree().change_scene_to_file.call_deferred(GAME_SCENE)
	return true


# --------------------------------------------------------------------------
# Costruzione
# --------------------------------------------------------------------------

func _build() -> void:
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))
	add_child(CastleBackdrop.new())

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", int(CastleBackdrop.COLUMN_W) + 14)
	margin.add_theme_constant_override("margin_right", int(CastleBackdrop.COLUMN_W) + 14)
	margin.add_theme_constant_override("margin_top", int(CastleBackdrop.SPRING_Y) + 16)
	margin.add_theme_constant_override("margin_bottom", int(CastleBackdrop.FLOOR_H) + 6)
	add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)

	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 16)
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_column)

	add_child(_build_language_switch())


## Un chi arriva qui per la prima volta non ha ancora visto le Impostazioni,
## quindi senza questo non avrebbe alcun modo di capire un'interfaccia in una
## lingua che non conosce. Sta fuori dalla colonna e sopravvive a _set_state():
## è una scelta di dispositivo, non legata allo stato LOGIN/SIGNUP/RESTORING.
func _build_language_switch() -> Control:
	var box := HBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.offset_left = -132
	box.offset_top = 14
	box.offset_right = -14
	box.offset_bottom = 14
	box.add_theme_constant_override("separation", 6)

	var current := String(get_node("/root/Profile").locale)
	box.add_child(_language_switch_button("IT", "it", current))
	box.add_child(_language_switch_button("EN", "en", current))
	return box


func _language_switch_button(label: String, locale_id: String, current: String) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(52, 44)
	button.add_theme_font_size_override("font_size", 16)
	if locale_id == current or (current == "" and locale_id == "it"):
		Style.apply_plate(button, Style.GOLD, Style.GOLD_DEEP, 12, 4)
		button.add_theme_color_override("font_color", Style.INK)
	else:
		Style.apply_plate(button, Style.PLATE, Style.PLATE_DARK, 12, 4)
	button.pressed.connect(func() -> void:
		get_node("/root/Profile").set_locale(locale_id)
		get_tree().reload_current_scene())
	return button


## Ricostruisce solo il contenuto della colonna: titolo, campi e azioni
## cambiano da stato a stato, ma il fondale e la cornice restano.
func _set_state(state: int) -> void:
	_state = state
	_busy = false
	for child in _column.get_children():
		_column.remove_child(child)
		# queue_free e non free: _set_state() arriva spesso dal lambda di un
		# pulsante di questa stessa colonna, che sta ancora emettendo il
		# proprio segnale — liberarlo subito lo ucciderebbe sotto i piedi.
		child.queue_free()
	_email_edit = null
	_password_edit = null
	_confirm_edit = null
	_username_edit = null

	_column.add_child(Style.title_plate())

	match state:
		State.RESTORING:
			_build_restoring()
		State.LOGIN:
			_build_login()
		State.SIGNUP:
			_build_signup()


func _title(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 30)
	label.add_theme_color_override("font_color", Style.GOLD)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_column.add_child(label)


func _build_restoring() -> void:
	var label := Label.new()
	label.text = tr("LOGIN_RESTORING")
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Style.TEXT_DIM)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_column.add_child(label)


func _build_login() -> void:
	_title(tr("LOGIN_TITLE"))

	_email_edit = _line_edit(tr("LOGIN_EMAIL"))
	_column.add_child(_email_edit)
	_password_edit = _line_edit(tr("LOGIN_PASSWORD"))
	_password_edit.text_submitted.connect(func(_t: String) -> void: _on_primary_pressed())
	_column.add_child(_password_field(_password_edit))

	_primary_text = tr("LOGIN_TITLE")
	_primary_button = _plate_button(_primary_text, Style.GOLD, Style.GOLD_DEEP, Style.TOUCH_PRIMARY)
	_primary_button.pressed.connect(_on_primary_pressed)
	_column.add_child(_primary_button)

	_column.add_child(_link_button(tr("LOGIN_GO_SIGNUP"),
		func() -> void: _set_state(State.SIGNUP)))

	_column.add_child(_separator(tr("LOGIN_OR")))
	_column.add_child(_provider_buttons())

	_error_label = _build_error_label()
	_column.add_child(_error_label)


func _build_signup() -> void:
	_title(tr("LOGIN_SIGNUP_TITLE"))

	_username_edit = _line_edit(tr("LOGIN_USERNAME"))
	_column.add_child(_username_edit)
	_email_edit = _line_edit(tr("LOGIN_EMAIL"))
	_column.add_child(_email_edit)
	_password_edit = _line_edit(tr("LOGIN_PASSWORD_MIN8"))
	_column.add_child(_password_field(_password_edit))
	_confirm_edit = _line_edit(tr("LOGIN_PASSWORD_CONFIRM"))
	_confirm_edit.text_submitted.connect(func(_t: String) -> void: _on_primary_pressed())
	_column.add_child(_password_field(_confirm_edit))

	_primary_text = tr("LOGIN_SIGNUP_TITLE")
	_primary_button = _plate_button(_primary_text, Style.GOLD, Style.GOLD_DEEP, Style.TOUCH_PRIMARY)
	_primary_button.pressed.connect(_on_primary_pressed)
	_column.add_child(_primary_button)

	_column.add_child(_link_button(tr("LOGIN_GO_LOGIN"),
		func() -> void: _set_state(State.LOGIN)))

	_column.add_child(_separator(tr("LOGIN_OR")))
	_column.add_child(_provider_buttons())

	_error_label = _build_error_label()
	_column.add_child(_error_label)


## "Continua con Google" e "Gioca come ospite": presenti in entrambi gli stati,
## sotto al separatore.
func _provider_buttons() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)

	_google_button = _plate_button(tr("LOGIN_GOOGLE"), Style.BLUE, Style.BLUE_DEEP, Style.TOUCH_MIN)
	_google_button.pressed.connect(_on_google_pressed)
	box.add_child(_google_button)

	_guest_button = Button.new()
	_guest_button.text = tr("LOGIN_GUEST")
	_guest_button.flat = true
	_guest_button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	_guest_button.add_theme_font_size_override("font_size", 18)
	_guest_button.add_theme_color_override("font_color", Style.TEXT_DIM)
	_guest_button.pressed.connect(_on_guest_pressed)
	box.add_child(_guest_button)

	return box


func _line_edit(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(0, 72)
	edit.add_theme_font_size_override("font_size", 20)
	edit.add_theme_stylebox_override("normal", Style.box(Style.PLATE_DARK, Style.PLATE))
	edit.add_theme_stylebox_override("focus", Style.box(Style.PLATE_DARK, Style.GOLD_DEEP, 2))
	return edit


## Marca `edit` come campo password (nascosto di default) e lo affianca a un
## pulsante occhio che ne mostra/nasconde il testo — senza, chi sbaglia un
## carattere in una password lunga non ha modo di controllare cosa ha scritto.
## Ritorna la riga da aggiungere alla colonna; `edit` resta l'oggetto da cui
## leggere .text, esattamente come prima di essere avvolto.
func _password_field(edit: LineEdit) -> Control:
	edit.secret = true
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var toggle := Button.new()
	toggle.text = "👁"
	toggle.custom_minimum_size = Vector2(56, 72)
	toggle.add_theme_font_size_override("font_size", 22)
	Style.apply_button(toggle, Style.PLATE_DARK, Style.PLATE)
	toggle.pressed.connect(func() -> void:
		edit.secret = not edit.secret
		toggle.text = "🙈" if edit.secret else "👁"
		# Il click sposta il focus sul pulsante: lo si restituisce al campo,
		# altrimenti chi sta scrivendo la password perde il cursore.
		edit.grab_focus())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(edit)
	row.add_child(toggle)
	return row


func _plate_button(text: String, fill: Color, edge: Color, min_height: int) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, min_height)
	button.add_theme_font_size_override("font_size", 22)
	Style.apply_plate(button, fill, edge, 18, 6)
	if fill == Style.GOLD:
		button.add_theme_color_override("font_color", Style.INK)
	return button


func _link_button(text: String, on_press: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.flat = true
	button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", Style.BLUE)
	button.pressed.connect(on_press)
	return button


func _separator(text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var left := ColorRect.new()
	left.color = Style.TEXT_DIM.darkened(0.3)
	left.custom_minimum_size = Vector2(0, 1)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(left)

	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Style.TEXT_DIM)
	row.add_child(label)

	var right := ColorRect.new()
	right.color = Style.TEXT_DIM.darkened(0.3)
	right.custom_minimum_size = Vector2(0, 1)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(right)

	return row


func _build_error_label() -> Label:
	var label := Label.new()
	label.text = ""
	label.visible = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.92, 0.42, 0.40))
	return label


# --------------------------------------------------------------------------
# Comportamento
# --------------------------------------------------------------------------

func _on_primary_pressed() -> void:
	if _busy:
		return
	if _state == State.LOGIN:
		_try_login()
	else:
		_try_signup()


func _try_login() -> void:
	var email := _email_edit.text.strip_edges()
	var password := _password_edit.text
	var problem := _validate_login(email, password)
	if problem != "":
		_show_error(problem)
		return
	_set_busy(true)
	_auth.login_email(email, password)


func _try_signup() -> void:
	var username_text := _username_edit.text.strip_edges()
	var email := _email_edit.text.strip_edges()
	var password := _password_edit.text
	var confirm := _confirm_edit.text
	var problem := _validate_signup(username_text, email, password, confirm)
	if problem != "":
		_show_error(problem)
		return
	_set_busy(true)
	_auth.register_email(email, password, username_text)


func _validate_login(email: String, password: String) -> String:
	if not _auth.email_looks_valid(email):
		return tr("LOGIN_CHECK_EMAIL")
	var pw_problem := String(_auth.password_problem(password))
	if pw_problem != "":
		return pw_problem
	return ""


func _validate_signup(username_text: String, email: String, password: String, confirm: String) -> String:
	if username_text == "":
		return tr("LOGIN_CHOOSE_USERNAME")
	if not _auth.email_looks_valid(email):
		return tr("LOGIN_CHECK_EMAIL")
	var pw_problem := String(_auth.password_problem(password))
	if pw_problem != "":
		return pw_problem
	if password != confirm:
		return tr("LOGIN_PASSWORDS_DONT_MATCH")
	return ""


func _on_google_pressed() -> void:
	if _google_waiting:
		_auth.cancel_login()
		_set_google_waiting(false)
		_set_busy(false)
		return
	if _busy:
		return
	_set_busy(true)
	_auth.login_google()
	_set_google_waiting(_auth.google_pending())


func _on_guest_pressed() -> void:
	_auth.continue_as_guest()
	_go_to_menu()


func _on_login_completed(success: bool, reason: String) -> void:
	if not is_inside_tree():
		return
	if success:
		_go_to_menu()
		return
	_set_google_waiting(false)
	_set_busy(false)
	var reason_key: String = String(REASON_KEYS.get(reason, ""))
	_show_error(tr(reason_key) if reason_key != "" else tr("LOGIN_FAILED"))


func _on_restore_finished(success: bool) -> void:
	if success:
		_go_to_menu()
	else:
		_set_state(State.LOGIN)


## Il pulsante Google diventa "annulla" finche' il consenso e' in sospeso.
func _set_google_waiting(waiting: bool) -> void:
	_google_waiting = waiting
	if _google_button == null:
		return
	_google_button.disabled = _busy and not waiting
	_google_button.text = tr("LOGIN_GOOGLE_WAITING") if waiting else tr("LOGIN_GOOGLE")


func _set_busy(busy: bool) -> void:
	_busy = busy
	if _primary_button != null:
		_primary_button.disabled = busy
		_primary_button.text = "…" if busy else _primary_text
	if _google_button != null:
		# Mentre si aspetta Google il pulsante resta vivo: e' l'annulla.
		_google_button.disabled = busy and not _google_waiting
	if _guest_button != null:
		_guest_button.disabled = busy
	if _email_edit != null:
		_email_edit.editable = not busy
	if _password_edit != null:
		_password_edit.editable = not busy
	if _confirm_edit != null:
		_confirm_edit.editable = not busy
	if _username_edit != null:
		_username_edit.editable = not busy


func _show_error(message: String) -> void:
	if _error_label == null:
		return
	_error_label.text = message
	_error_label.visible = message != ""
