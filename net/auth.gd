extends Node

## Autenticazione dell'account online (Google, backend self-hosted).
## Registrato come autoload "Auth" (vedi project.godot).
##
## Stessa filosofia di monetization/store.gd: è una facciata che degrada a
## no-op quando il backend non è disponibile. Se data/backend.json ha valori
## segnaposto, non c'è rete, o il refresh fallisce, si resta OSPITI e il
## single-player continua a funzionare identico, senza login e offline.
##
## Login: flusso loopback + PKCE (RFC 8252). Nessun plugin nativo, nessun
## deep link. Si apre il browser di sistema su accounts.google.com; Google
## redirige su http://127.0.0.1:<porta>/callback; un TCPServer locale cattura il
## `code`. Lo SCAMBIO del code NON avviene qui: `code` + `code_verifier` vengono
## inoltrati al MASTER via WebSocket (il master tiene GOOGLE_CLIENT_SECRET e non
## lo mette mai nell'APK). Il master risponde con AUTH_OK, che porta un token di
## sessione firmato da lui + un refresh token opaco + il bundle del profilo.
##
## Gli autoload si prendono con get_node("/root/Auth"), MAI per nome globale:
## gli script compilati da riga di comando (test headless) non li risolvono.

signal login_completed(success: bool, reason: String)
## Emesso quando try_restore_session() ha finito, in entrambi gli esiti. La
## schermata di login lo aspetta prima di decidere se mostrarsi.
signal session_restore_finished(success: bool)
signal logged_out
## Esito di delete_account(): success=true dopo ACCOUNT_DELETED dal master (segue
## un logout automatico). success=false se la richiesta è fallita.
signal account_deletion_completed(success: bool)

const CONFIG_PATH := "res://data/backend.json"
const TOKEN_PATH := "user://auth.dat"
const CALLBACK_HTML := "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:sans-serif;text-align:center;padding-top:3em\"><h2>Login completato</h2><p>Torna al gioco.</p></body></html>"

const HOST_PLACEHOLDERS := ["tuodominio", "your-", "yourdomain", "example.", "changeme", "placeholder"]
const CLIENT_ID_PLACEHOLDER := "REPLACE_WITH_GOOGLE_CLIENT_ID"

## Dati di account esposti alla UI (popolati da AUTH_OK). Senza login sono vuoti.
var username: String = ""
var owned_civs: PackedStringArray = PackedStringArray()
var stats: Dictionary = {}
var favourite_origin: String = ""
var favourite_hero: String = ""

var _host: String = ""
var _google_client_id: String = ""

var _access_token: String = ""
var _refresh_token: String = ""
var _user_id: String = ""

# --- flusso loopback OAuth ---
var _server: TCPServer = null
var _port: int = 0
var _code_verifier: String = ""
var _redirect_uri: String = ""
var _pending: bool = false
var _deadline: float = 0.0
var _login_source: String = ""
var _restoring: bool = false

# --- richieste one-shot al master (WebSocket) ---
var _ws: WebSocketPeer = null
var _ws_sent: bool = false
var _ws_deadline: float = 0.0
var _ws_current: Dictionary = {}     # {send, reply_types: Array, cb: Callable}
var _ws_queue: Array = []            # code di richieste in attesa


func _ready() -> void:
	_load_config()
	if not is_configured():
		print("[Auth] backend non configurato: modalità ospite")
		return
	print("[Auth] backend: %s" % _host)
	try_restore_session()


func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_host = String(parsed.get("game_host", "")).strip_edges()
	_google_client_id = String(parsed.get("google_client_id", "")).strip_edges()


## Vero solo se data/backend.json ha valori reali (non i segnaposto tracciati).
func is_configured() -> bool:
	if _host == "" or _google_client_id == "" or _google_client_id == CLIENT_ID_PLACEHOLDER:
		return false
	var lower := _host.to_lower()
	for placeholder in HOST_PLACEHOLDERS:
		if placeholder in lower:
			return false
	return true


# --------------------------------------------------------------------------
# Interrogazioni
# --------------------------------------------------------------------------

func is_logged_in() -> bool:
	return _access_token != ""


## Vero mentre try_restore_session() è in volo. La schermata di login lo usa per
## mostrare "Accesso in corso…" invece dei campi finché non arriva l'esito.
func restore_pending() -> bool:
	return _restoring


## Modalità ospite: si gioca offline contro i bot, niente multiplayer né
## statistiche. La scelta si ricorda in Profile, altrimenti la schermata di
## login tornerebbe a ogni avvio a chi ha già detto di no.
func continue_as_guest() -> void:
	var profile := get_node_or_null("/root/Profile")
	if profile != null:
		profile.set_guest_mode(true)


func is_guest() -> bool:
	var profile := get_node_or_null("/root/Profile")
	return profile != null and profile.guest_mode


## Uuid del profilo lato server. "" se sloggato.
func user_id() -> String:
	return _user_id if is_logged_in() else ""


## Token di sessione firmato dal master (usato in HELLO). "" se sloggato.
func access_token() -> String:
	return _access_token if is_logged_in() else ""


## Host del backend da data/backend.json ("" se coi segnaposto). Usato dalla UI
## per costruire i link a /privacy e /elimina-account.
func game_host() -> String:
	return _host if is_configured() else ""


# --------------------------------------------------------------------------
# Comandi
# --------------------------------------------------------------------------

## Avvia il flusso loopback + PKCE nel browser di sistema (verso Google).
func login_google() -> void:
	if _pending:
		return
	if not is_configured():
		login_completed.emit(false, "backend non configurato")
		return

	_server = TCPServer.new()
	var bound := false
	for port in range(51000, 51060):
		if _server.listen(port, "127.0.0.1") == OK:
			_port = port
			bound = true
			break
	if not bound:
		_cleanup_server()
		login_completed.emit(false, "nessuna porta di loopback disponibile")
		return

	_code_verifier = _random_verifier()
	var challenge := _base64url(_sha256(_code_verifier))
	_redirect_uri = "http://127.0.0.1:%d/callback" % _port
	var url := "https://accounts.google.com/o/oauth2/v2/auth?client_id=%s&redirect_uri=%s&response_type=code&scope=%s&code_challenge=%s&code_challenge_method=S256" % [
		_google_client_id.uri_encode(),
		_redirect_uri.uri_encode(),
		"openid email profile".uri_encode(),
		challenge]

	_login_source = "login"
	_pending = true
	_deadline = _now() + 180.0
	OS.shell_open(url)


## Login con email e password. Emette login_completed(success, reason) come
## login_google(): la UI non deve distinguere il provider.
func login_email(email: String, password: String) -> void:
	if not is_configured():
		login_completed.emit(false, "backend non configurato")
		return
	_login_source = "login"
	_master_request(
		Protocol.make(Protocol.AUTH_EMAIL_LOGIN, {"email": email, "password": password}),
		[Protocol.AUTH_OK, Protocol.AUTH_FAIL],
		_on_auth_reply.bind("login"))


func register_email(email: String, password: String, username_in: String) -> void:
	if not is_configured():
		login_completed.emit(false, "backend non configurato")
		return
	_login_source = "login"
	_master_request(
		Protocol.make(Protocol.AUTH_EMAIL_SIGNUP,
			{"email": email, "password": password, "username": username_in}),
		[Protocol.AUTH_OK, Protocol.AUTH_FAIL],
		_on_auth_reply.bind("login"))


func logout() -> void:
	_access_token = ""
	_refresh_token = ""
	_user_id = ""
	username = ""
	owned_civs = PackedStringArray()
	stats = {}
	favourite_origin = ""
	favourite_hero = ""
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists("auth.dat"):
		dir.remove("auth.dat")
	# Un logout deve poter far ricomparire la schermata di login anche a chi
	# aveva scelto "ospite".
	var profile := get_node_or_null("/root/Profile")
	if profile != null:
		profile.set_guest_mode(false)
	logged_out.emit()


## Chiamato in _ready(): tenta il refresh dal token salvato in user://auth.dat.
## In caso di fallimento si resta ospiti senza rumore (nessun login_completed).
func try_restore_session() -> void:
	if not is_configured() or not FileAccess.file_exists(TOKEN_PATH):
		return
	var f := FileAccess.open(TOKEN_PATH, FileAccess.READ)
	if f == null:
		return
	var rt := f.get_as_text().strip_edges()
	f.close()
	if rt == "":
		return
	_login_source = "restore"
	_restoring = true
	_master_request(
		Protocol.make(Protocol.AUTH_REFRESH, {"refresh_token": rt}),
		[Protocol.AUTH_OK, Protocol.AUTH_FAIL],
		_on_auth_reply.bind("restore"))


## Spinge le preferenze di account sul server (PROFILE_SET). No-op da sloggati.
func push_preferences(origin: String, hero: String) -> void:
	if not is_logged_in():
		return
	favourite_origin = origin
	favourite_hero = hero
	_master_request(
		Protocol.make(Protocol.PROFILE_SET, {
			"session_token": _access_token,
			"favourite_origin": origin,
			"favourite_hero": hero,
		}),
		[Protocol.PROFILE_OK, Protocol.AUTH_FAIL],
		func(_ok: bool, _msg: Dictionary) -> void: pass)


## Cancellazione irreversibile dell'account sul server. In caso di successo segue
## un logout automatico (token e user://auth.dat cancellati). Emette
## account_deletion_completed(success).
func delete_account() -> void:
	if not is_logged_in():
		account_deletion_completed.emit(false)
		return
	_master_request(
		Protocol.make(Protocol.DELETE_ACCOUNT, {"session_token": _access_token}),
		[Protocol.ACCOUNT_DELETED, Protocol.AUTH_FAIL],
		func(ok: bool, msg: Dictionary) -> void:
			var done := ok and Protocol.message_type(msg) == Protocol.ACCOUNT_DELETED
			if done:
				logout()
			account_deletion_completed.emit(done))


## Cronologia delle partite online del giocatore. cb.call(ok: bool, matches: Array),
## dalla piu' recente. Da sloggati o da ospiti risponde subito con una lista
## vuota: la schermata Cronologia mostrera' solo le partite locali, senza errori.
func request_history(limit: int, cb: Callable) -> void:
	if not is_logged_in():
		cb.call(false, [])
		return
	_master_request(
		Protocol.make(Protocol.HISTORY_REQUEST, {
			"session_token": _access_token,
			"limit": limit,
		}),
		[Protocol.HISTORY_DATA, Protocol.AUTH_FAIL],
		func(ok: bool, msg: Dictionary) -> void:
			var done := ok and Protocol.message_type(msg) == Protocol.HISTORY_DATA
			var matches: Array = msg.get("matches", []) if done else []
			cb.call(done, matches))


# --------------------------------------------------------------------------
# Pompa
# --------------------------------------------------------------------------

func _process(delta: float) -> void:
	_pump_loopback()
	_pump_ws()


func _pump_loopback() -> void:
	if not _pending or _server == null:
		return
	if _now() > _deadline:
		_fail_login("timeout del login")
		return
	if not _server.is_connection_available():
		return

	var conn := _server.take_connection()
	var request := ""
	var guard := 0
	while guard < 400:
		conn.poll()
		if conn.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var available := conn.get_available_bytes()
		if available > 0:
			request += conn.get_utf8_string(available)
			if request.contains("\r\n"):
				break
		guard += 1

	var code := _extract_code(request)
	var body := CALLBACK_HTML.to_utf8_buffer()
	var response := "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.size()
	conn.put_data(response.to_utf8_buffer())
	conn.put_data(body)
	conn.disconnect_from_host()
	_cleanup_server()

	if code == "":
		_fail_login("nessun code nella risposta OAuth")
		return
	_master_request(
		Protocol.make(Protocol.AUTH_GOOGLE, {
			"code": code,
			"code_verifier": _code_verifier,
			"redirect_uri": _redirect_uri,
		}),
		[Protocol.AUTH_OK, Protocol.AUTH_FAIL],
		_on_auth_reply.bind("login"))


func _pump_ws() -> void:
	if _ws == null:
		if not _ws_queue.is_empty():
			_ws_current = _ws_queue.pop_front()
			_open_ws()
		return

	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _ws_sent:
				_ws.put_packet(Protocol.encode(_ws_current.send))
				_ws_sent = true
			while _ws != null and _ws.get_available_packet_count() > 0:
				var msg := Protocol.decode(_ws.get_packet())
				if Protocol.message_type(msg) in _ws_current.reply_types:
					_finish_ws(true, msg)
					return
			if _now() > _ws_deadline:
				_finish_ws(false, {})
		WebSocketPeer.STATE_CLOSED:
			_finish_ws(false, {})
		_:
			if _now() > _ws_deadline:
				_finish_ws(false, {})


func _master_request(send_msg: Dictionary, reply_types: Array, cb: Callable) -> void:
	_ws_queue.append({"send": send_msg, "reply_types": reply_types, "cb": cb})


func _open_ws() -> void:
	if not is_configured():
		_finish_ws(false, {})
		return
	_ws = WebSocketPeer.new()
	_ws_sent = false
	_ws_deadline = _now() + 20.0
	if _ws.connect_to_url("wss://%s/ws/mm" % _host) != OK:
		_ws = null
		var cb: Callable = _ws_current.get("cb", Callable())
		_ws_current = {}
		if cb.is_valid():
			cb.call(false, {})


func _finish_ws(ok: bool, msg: Dictionary) -> void:
	var cb: Callable = _ws_current.get("cb", Callable())
	if _ws != null:
		_ws.close()
		_ws = null
	_ws_sent = false
	_ws_current = {}
	if cb.is_valid():
		cb.call(ok, msg)


# --------------------------------------------------------------------------
# Esiti auth
# --------------------------------------------------------------------------

func _on_auth_reply(ok: bool, msg: Dictionary, source: String) -> void:
	if ok and Protocol.message_type(msg) == Protocol.AUTH_OK:
		_apply_bundle(msg)
		_pending = false
		_cleanup_server()
		if source == "restore":
			_restoring = false
			session_restore_finished.emit(true)
		login_completed.emit(true, "")
		return

	var reason := "sessione non valida"
	if msg.has("reason"):
		reason = String(msg["reason"])
	if source == "restore":
		# refresh fallito: si resta ospiti in silenzio
		_pending = false
		_cleanup_server()
		_restoring = false
		session_restore_finished.emit(false)
		return
	_fail_login(reason)


func _apply_bundle(msg: Dictionary) -> void:
	_access_token = String(msg.get("session_token", ""))
	_refresh_token = String(msg.get("refresh_token", ""))
	_user_id = String(msg.get("user_id", ""))
	username = String(msg.get("username", ""))
	owned_civs = PackedStringArray(msg.get("owned_civs", []))
	stats = msg.get("stats", {})
	var prof: Dictionary = msg.get("profile", {})
	favourite_origin = String(prof.get("favourite_origin", ""))
	favourite_hero = String(prof.get("favourite_hero", ""))
	_save_refresh_token()


func _fail_login(reason: String) -> void:
	var was_restore := _login_source == "restore"
	_pending = false
	_code_verifier = ""
	_cleanup_server()
	if not was_restore:
		login_completed.emit(false, reason)


# --------------------------------------------------------------------------
# Utilità
# --------------------------------------------------------------------------

func _cleanup_server() -> void:
	if _server != null:
		_server.stop()
		_server = null


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _random_verifier() -> String:
	var chars := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
	var out := ""
	for i in 64:
		out += chars[randi() % chars.length()]
	return out


func _sha256(text: String) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish()


func _base64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")


func _extract_code(request: String) -> String:
	var lines := request.split("\r\n")
	if lines.size() == 0:
		return ""
	var first := lines[0]
	var q := first.find("?")
	if q == -1:
		return ""
	var query := first.substr(q + 1).split(" ")[0]
	for pair in query.split("&"):
		var kv := pair.split("=")
		if kv.size() == 2 and kv[0] == "code":
			return kv[1].uri_decode()
	return ""


static func email_looks_valid(email: String) -> bool:
	var e := email.strip_edges()
	var at := e.find("@")
	return at > 0 and e.find(".", at) > at + 1 and not e.contains(" ") and not e.ends_with(".")


## "" se la password va bene, altrimenti il messaggio da mostrare.
static func password_problem(password: String) -> String:
	if password.length() < 8:
		return "La password deve avere almeno 8 caratteri."
	return ""


func _save_refresh_token() -> void:
	if _refresh_token == "":
		return
	var f := FileAccess.open(TOKEN_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(_refresh_token)
		f.close()
