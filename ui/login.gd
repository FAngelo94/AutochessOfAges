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

enum State { RESTORING, LOGIN, SIGNUP }

const REASONS := {
	"email_taken": "Questa email è già registrata. Prova ad accedere.",
	"invalid_credentials": "Email o password non corretti.",
	"invalid": "Controlla email e password.",
	"rate_limited": "Troppi tentativi. Riprova tra qualche minuto.",
	"db": "Servizio non disponibile, riprova più tardi.",
	"google": "Accesso con Google non riuscito.",
}

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
var _guest_button: Button


func _ready() -> void:
	_auth = get_node_or_null("/root/Auth")
	# Backend segnaposto (test headless, sviluppo locale), sessione già valida o
	# scelta "ospite" già fatta: non c'è niente da chiedere.
	if _auth == null or not _auth.is_configured() or _auth.is_logged_in() or _auth.is_guest():
		_go_to_menu()
		return
	_auth.login_completed.connect(_on_login_completed)
	_auth.session_restore_finished.connect(_on_restore_finished)
	_build()
	_set_state(State.RESTORING if _auth.restore_pending() else State.LOGIN)


func _go_to_menu() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)


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


## Ricostruisce solo il contenuto della colonna: titolo, campi e azioni
## cambiano da stato a stato, ma il fondale e la cornice restano.
func _set_state(state: int) -> void:
	_state = state
	_busy = false
	for child in _column.get_children():
		_column.remove_child(child)
		child.free()
	_email_edit = null
	_password_edit = null
	_confirm_edit = null
	_username_edit = null

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
	_title("AUTOCHESS OF AGES")
	var label := Label.new()
	label.text = "Accesso in corso…"
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Style.TEXT_DIM)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_column.add_child(label)


func _build_login() -> void:
	_title("ACCEDI")

	_email_edit = _line_edit("Email", false)
	_column.add_child(_email_edit)
	_password_edit = _line_edit("Password", true)
	_password_edit.text_submitted.connect(func(_t: String) -> void: _on_primary_pressed())
	_column.add_child(_password_edit)

	_primary_text = "ACCEDI"
	_primary_button = _plate_button(_primary_text, Style.GOLD, Style.GOLD_DEEP, Style.TOUCH_PRIMARY)
	_primary_button.pressed.connect(_on_primary_pressed)
	_column.add_child(_primary_button)

	_column.add_child(_link_button("Non hai un account? Registrati",
		func() -> void: _set_state(State.SIGNUP)))

	_column.add_child(_separator("oppure"))
	_column.add_child(_provider_buttons())

	_error_label = _build_error_label()
	_column.add_child(_error_label)


func _build_signup() -> void:
	_title("CREA ACCOUNT")

	_username_edit = _line_edit("Nome giocatore", false)
	_column.add_child(_username_edit)
	_email_edit = _line_edit("Email", false)
	_column.add_child(_email_edit)
	_password_edit = _line_edit("Password (almeno 8 caratteri)", true)
	_column.add_child(_password_edit)
	_confirm_edit = _line_edit("Conferma password", true)
	_confirm_edit.text_submitted.connect(func(_t: String) -> void: _on_primary_pressed())
	_column.add_child(_confirm_edit)

	_primary_text = "CREA ACCOUNT"
	_primary_button = _plate_button(_primary_text, Style.GOLD, Style.GOLD_DEEP, Style.TOUCH_PRIMARY)
	_primary_button.pressed.connect(_on_primary_pressed)
	_column.add_child(_primary_button)

	_column.add_child(_link_button("Hai già un account? Accedi",
		func() -> void: _set_state(State.LOGIN)))

	_column.add_child(_separator("oppure"))
	_column.add_child(_provider_buttons())

	_error_label = _build_error_label()
	_column.add_child(_error_label)


## "Continua con Google" e "Gioca come ospite": presenti in entrambi gli stati,
## sotto al separatore.
func _provider_buttons() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)

	_google_button = _plate_button("Continua con Google", Style.BLUE, Style.BLUE_DEEP, Style.TOUCH_MIN)
	_google_button.pressed.connect(_on_google_pressed)
	box.add_child(_google_button)

	_guest_button = Button.new()
	_guest_button.text = "Gioca come ospite"
	_guest_button.flat = true
	_guest_button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	_guest_button.add_theme_font_size_override("font_size", 18)
	_guest_button.add_theme_color_override("font_color", Style.TEXT_DIM)
	_guest_button.pressed.connect(_on_guest_pressed)
	box.add_child(_guest_button)

	return box


func _line_edit(placeholder: String, secret: bool) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.secret = secret
	edit.custom_minimum_size = Vector2(0, 72)
	edit.add_theme_font_size_override("font_size", 20)
	edit.add_theme_stylebox_override("normal", Style.box(Style.PLATE_DARK, Style.PLATE))
	edit.add_theme_stylebox_override("focus", Style.box(Style.PLATE_DARK, Style.GOLD_DEEP, 2))
	return edit


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
		return "Controlla l'indirizzo email."
	var pw_problem := String(_auth.password_problem(password))
	if pw_problem != "":
		return pw_problem
	return ""


func _validate_signup(username_text: String, email: String, password: String, confirm: String) -> String:
	if username_text == "":
		return "Scegli un nome giocatore."
	if not _auth.email_looks_valid(email):
		return "Controlla l'indirizzo email."
	var pw_problem := String(_auth.password_problem(password))
	if pw_problem != "":
		return pw_problem
	if password != confirm:
		return "Le password non coincidono."
	return ""


func _on_google_pressed() -> void:
	if _busy:
		return
	_set_busy(true)
	_auth.login_google()


func _on_guest_pressed() -> void:
	_auth.continue_as_guest()
	_go_to_menu()


func _on_login_completed(success: bool, reason: String) -> void:
	if not is_inside_tree():
		return
	if success:
		_go_to_menu()
		return
	_set_busy(false)
	_show_error(String(REASONS.get(reason, "Accesso non riuscito.")))


func _on_restore_finished(success: bool) -> void:
	if success:
		_go_to_menu()
	else:
		_set_state(State.LOGIN)


func _set_busy(busy: bool) -> void:
	_busy = busy
	if _primary_button != null:
		_primary_button.disabled = busy
		_primary_button.text = "…" if busy else _primary_text
	if _google_button != null:
		_google_button.disabled = busy
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
