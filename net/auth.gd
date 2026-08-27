extends Node

## Autenticazione dell'account online (Google via Supabase OAuth).
## Registrato come autoload "Auth" (vedi project.godot).
##
## Stessa filosofia di monetization/store.gd: è una facciata che degrada a
## no-op quando il backend non è disponibile. Se data/backend.json ha valori
## segnaposto, non c'è rete, o il refresh fallisce, si resta OSPITI e il
## single-player continua a funzionare identico, senza login e offline.
##
## Login: flusso loopback + PKCE (RFC 8252). Nessun plugin nativo, nessun
## deep link, nessun gradle build: si apre il browser di sistema, Supabase
## redirige su http://127.0.0.1:<porta>/callback, un TCPServer locale cattura
## il code, che viene scambiato per i token via HTTPRequest.
##
## Gli autoload si prendono con get_node("/root/Auth"), MAI per nome globale:
## gli script compilati da riga di comando (test headless) non li risolvono.

signal login_completed(success: bool, reason: String)
signal logged_out

const TOKEN_PATH := "user://auth.dat"
const CALLBACK_HTML := "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:sans-serif;text-align:center;padding-top:3em\"><h2>Login completato</h2><p>Torna al gioco.</p></body></html>"

var _client: SupabaseClient
var _access_token: String = ""
var _refresh_token: String = ""
var _user_id: String = ""

var _server: TCPServer = null
var _port: int = 0
var _code_verifier: String = ""
var _pending: bool = false
var _deadline: float = 0.0
var _login_source: String = ""


func _ready() -> void:
	_client = SupabaseClient.new(self)
	if not _client.is_configured():
		print("[Auth] backend non configurato: modalità ospite")
		return
	print("[Auth] backend: %s" % _client.supabase_url)
	try_restore_session()


# --------------------------------------------------------------------------
# Interrogazioni
# --------------------------------------------------------------------------

func is_logged_in() -> bool:
	return _access_token != ""


## Il "sub" del JWT = uuid Supabase dell'utente. "" se sloggato.
func user_id() -> String:
	return _user_id if is_logged_in() else ""


## Access token (JWT) corrente. "" se sloggato.
func access_token() -> String:
	return _access_token if is_logged_in() else ""


# --------------------------------------------------------------------------
# Comandi
# --------------------------------------------------------------------------

## Avvia il flusso loopback + PKCE nel browser di sistema.
func login_google() -> void:
	if _pending:
		return
	if _client == null or not _client.is_configured():
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
	var redirect := "http://127.0.0.1:%d/callback" % _port
	var url := "%s/auth/v1/authorize?provider=google&redirect_to=%s&code_challenge=%s&code_challenge_method=S256" % [
		_client.supabase_url, redirect.uri_encode(), challenge]

	_login_source = "login"
	_pending = true
	_deadline = _now() + 180.0
	OS.shell_open(url)


func logout() -> void:
	_access_token = ""
	_refresh_token = ""
	_user_id = ""
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists("auth.dat"):
		dir.remove("auth.dat")
	logged_out.emit()


## Chiamato in _ready(): tenta il refresh dal token salvato in user://auth.dat.
## In caso di fallimento si resta ospiti senza rumore (nessun login_completed).
func try_restore_session() -> void:
	if _client == null or not _client.is_configured():
		return
	if not FileAccess.file_exists(TOKEN_PATH):
		return
	var f := FileAccess.open(TOKEN_PATH, FileAccess.READ)
	if f == null:
		return
	var rt := f.get_as_text().strip_edges()
	f.close()
	if rt == "":
		return
	_login_source = "restore"
	_client.token_from_refresh(rt, _on_token_response)


# --------------------------------------------------------------------------
# Loop del callback loopback
# --------------------------------------------------------------------------

func _process(_delta: float) -> void:
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
	_client.token_from_pkce(code, _code_verifier, _on_token_response)


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


func _on_token_response(success: bool, data: Variant) -> void:
	var dict: Dictionary = data if data is Dictionary else {}
	if success and dict.has("access_token"):
		_access_token = String(dict.get("access_token", ""))
		_refresh_token = String(dict.get("refresh_token", ""))
		_user_id = _sub_from_jwt(_access_token)
		_save_refresh_token()
		_pending = false
		_cleanup_server()
		login_completed.emit(true, "")
		return

	var reason := "sessione non valida"
	if dict.has("error_description"):
		reason = String(dict["error_description"])
	elif dict.has("msg"):
		reason = String(dict["msg"])
	_fail_login(reason)


func _fail_login(reason: String) -> void:
	var was_restore := _login_source == "restore"
	_pending = false
	_code_verifier = ""
	_cleanup_server()
	if not was_restore:
		login_completed.emit(false, reason)


# --------------------------------------------------------------------------
# Utilità

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


func _sub_from_jwt(jwt: String) -> String:
	var parts := jwt.split(".")
	if parts.size() < 2:
		return ""
	var payload: String = parts[1].replace("-", "+").replace("_", "/")
	while payload.length() % 4 != 0:
		payload += "="
	var raw := Marshalls.base64_to_raw(payload)
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY:
		return String((parsed as Dictionary).get("sub", ""))
	return ""


func _save_refresh_token() -> void:
	if _refresh_token == "":
		return
	var f := FileAccess.open(TOKEN_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(_refresh_token)
		f.close()
