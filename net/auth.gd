extends Node

## Autenticazione dell'account online (Google, backend self-hosted).
## Registrato come autoload "Auth" (vedi project.godot).
##
## Stessa filosofia di monetization/store.gd: è una facciata che degrada a
## no-op quando il backend non è disponibile. Se data/backend.json ha valori
## segnaposto, non c'è rete, o il refresh fallisce, si resta OSPITI e il
## single-player continua a funzionare identico, senza login e offline.
##
## Login Google: il consenso lo chiude il SERVER, non l'app. Il client chiede al
## master un URL di consenso (AUTH_GOOGLE_BEGIN -> AUTH_GOOGLE_URL), apre il
## browser di sistema, e poi si limita a richiedere l'esito (AUTH_GOOGLE_POLL)
## finche' non arriva AUTH_OK. Google redirige su https://<host>/oauth/cb, che e'
## il master: lo scambio del code e il client_secret restano dalla sua parte e
## non finiscono mai nell'APK.
##
## Il flusso loopback (RFC 8252, un TCPServer su 127.0.0.1 dentro l'app) e'
## stato tolto perche' e' un flusso DESKTOP: su Android, appena OS.shell_open()
## manda il browser in primo piano, l'activity di Godot va in pausa e il main
## loop si ferma. _process() non gira, nessuna connessione viene accettata, il
## code non viene mai raccolto e il login scade. Con il consenso chiuso sul
## server questo non conta piu': la sessione e' gia' pronta quando il giocatore
## torna nell'app, comunque ci torni.
##
## Per lo stesso motivo il login in corso si salva su disco (PENDING_PATH): se
## Android uccide il gioco mentre si e' nel browser, alla riapertura si ritira
## la sessione invece di ricominciare.
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
## Login Google iniziato e non ancora concluso: {state, started} (unix time, non
## ticks — l'app puo' essere stata chiusa e riaperta nel frattempo).
const PENDING_PATH := "user://oauth_pending.dat"
## Deve restare <= a OAuthPending.TTL_SECONDS del master: e' il tempo concesso
## al giocatore per completare il consenso nel browser.
const OAUTH_TTL := 600.0
## Ritmo con cui si richiede l'esito. Basso: sono pacchetti minuscoli e il
## giocatore sta aspettando davanti a una schermata.
const POLL_INTERVAL := 2.0

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

# --- login Google in corso ---
var _oauth_state: String = ""
var _poll_at: float = 0.0
var _poll_inflight: bool = false
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
	# Un consenso lasciato a meta' ha la precedenza sul refresh: chi era nel
	# browser un attimo fa sta finendo QUEL login, non riprendendo il vecchio.
	if _resume_pending_login():
		return
	try_restore_session()


func _notification(what: int) -> void:
	# Ritorno in primo piano. Su Android il main loop e' stato fermo per tutto
	# il tempo del consenso: si richiede subito l'esito invece di aspettare il
	# prossimo tick di POLL_INTERVAL.
	if what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_poll_at = 0.0


func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_host = String(parsed.get("game_host", "")).strip_edges()
	_google_client_id = String(parsed.get("google_client_id", "")).strip_edges()


## Vero solo se data/backend.json ha valori reali (non i segnaposto tracciati).
## `google_client_id` qui serve solo da interruttore: l'URL di consenso lo
## costruisce il master, che e' l'unico a dover conoscere davvero il client
## OAuth. Deve comunque essere quello giusto, o il pulsante Google compare su un
## backend che non sa fare login.
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

## Apre il consenso Google nel browser di sistema. Il ritorno NON passa da qui:
## Google redirige sul master, e da li' in poi si ritira l'esito con
## AUTH_GOOGLE_POLL a ogni frame utile (vedi _pump_google).
func login_google() -> void:
	if _pending:
		return
	if not is_configured():
		login_completed.emit(false, "backend non configurato")
		return
	_login_source = "login"
	_pending = true
	_deadline = _now() + OAUTH_TTL
	_master_request(
		Protocol.make(Protocol.AUTH_GOOGLE_BEGIN),
		[Protocol.AUTH_GOOGLE_URL, Protocol.AUTH_FAIL],
		_on_google_begin)


## Abbandona un consenso in corso (browser chiuso, ripensamento). Non emette
## nulla: e' la UI a sapere di averlo chiesto.
func cancel_login() -> void:
	if not google_pending():
		return
	_forget_pending()
	_pending = false
	_restoring = false


## Vero fra l'apertura del browser e l'esito del consenso.
func google_pending() -> bool:
	return _oauth_state != ""


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


## Classifica per mmr: primi `limit` giocatori e la propria riga.
## cb.call(ok: bool, data: Dictionary) con {top: Array, me: Dictionary} — `me`
## vuoto se non si ha ancora una partita classificata. Da sloggati o da ospiti
## risponde subito con esito negativo: la classifica esiste solo per gli account.
func request_leaderboard(limit: int, cb: Callable) -> void:
	if not is_logged_in():
		cb.call(false, {})
		return
	_master_request(
		Protocol.make(Protocol.LEADERBOARD_REQUEST, {
			"session_token": _access_token,
			"limit": limit,
		}),
		[Protocol.LEADERBOARD_DATA, Protocol.AUTH_FAIL],
		func(ok: bool, msg: Dictionary) -> void:
			var done := ok and Protocol.message_type(msg) == Protocol.LEADERBOARD_DATA
			cb.call(done, msg if done else {}))


## Stato del Crowdfunding Store: totale raccolto, obiettivo, sostenitori e le
## proprie donazioni. cb.call(ok: bool, data: Dictionary).
##
## Il totale lo calcola il server dalle righe scritte dal webhook di RevenueCat:
## il client non lo somma da sé, perché una barra pubblica che ognuno può
## gonfiare non varrebbe niente. Da sloggati o da ospiti risponde subito con un
## esito negativo e il pannello lo dice, invece di mostrare uno zero finto.
func request_donations(limit: int, cb: Callable) -> void:
	if not is_logged_in():
		cb.call(false, {})
		return
	_master_request(
		Protocol.make(Protocol.DONATIONS_REQUEST, {
			"session_token": _access_token,
			"limit": limit,
		}),
		[Protocol.DONATIONS_DATA, Protocol.AUTH_FAIL],
		func(ok: bool, msg: Dictionary) -> void:
			var done := ok and Protocol.message_type(msg) == Protocol.DONATIONS_DATA
			cb.call(done, msg if done else {}))


# --------------------------------------------------------------------------
# Pompa
# --------------------------------------------------------------------------

func _process(_delta: float) -> void:
	_pump_google()
	_pump_ws()


## Richiede al master l'esito del consenso finche' non arriva o non scade. Una
## richiesta alla volta: senza il guardiano, ogni frame ne accoderebbe una e la
## coda crescerebbe piu' in fretta di quanto la si svuota.
func _pump_google() -> void:
	if _oauth_state == "" or _poll_inflight:
		return
	if _now() > _deadline:
		_forget_pending()
		_fail_login("timeout del login")
		return
	if _now() < _poll_at:
		return
	_poll_inflight = true
	_master_request(
		Protocol.make(Protocol.AUTH_GOOGLE_POLL, {"state": _oauth_state}),
		[Protocol.AUTH_OK, Protocol.AUTH_PENDING, Protocol.AUTH_FAIL],
		_on_google_poll)


func _on_google_begin(ok: bool, msg: Dictionary) -> void:
	if not ok or Protocol.message_type(msg) != Protocol.AUTH_GOOGLE_URL:
		_fail_login(String(msg.get("reason", "server non raggiungibile")))
		return
	_oauth_state = String(msg.get("state", ""))
	var url := String(msg.get("auth_url", ""))
	if _oauth_state == "" or url == "":
		_oauth_state = ""
		_fail_login("risposta di login malformata")
		return
	_save_pending()
	_poll_at = _now() + POLL_INTERVAL
	OS.shell_open(url)


func _on_google_poll(ok: bool, msg: Dictionary) -> void:
	_poll_inflight = false
	_poll_at = _now() + POLL_INTERVAL
	if not ok:
		# WebSocket caduta o scaduta. Mentre l'app e' in background succede di
		# continuo (il main loop e' fermo, la connessione muore): non e' il
		# login ad essere fallito, si riprova fino a _deadline.
		return
	match Protocol.message_type(msg):
		Protocol.AUTH_OK:
			_on_auth_reply(true, msg, _login_source)
		Protocol.AUTH_PENDING:
			pass    # consenso ancora in corso nel browser
		_:
			var reason := String(msg.get("reason", "sessione non valida"))
			_forget_pending()
			_fail_login(reason)


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
		_forget_pending()
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
		_forget_pending()
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
	_forget_pending()
	if was_restore:
		# Ripresa silenziosa (refresh o consenso recuperato dal disco): si resta
		# ospiti senza errori, ma la schermata di login aspetta comunque di
		# sapere che ha finito, altrimenti resta su "Accesso in corso…".
		if _restoring:
			_restoring = false
			session_restore_finished.emit(false)
		return
	login_completed.emit(false, reason)


# --------------------------------------------------------------------------
# Utilità
# --------------------------------------------------------------------------

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Salva il consenso in corso. Serve solo su mobile, dove il sistema puo'
## uccidere il gioco mentre il giocatore e' nel browser: senza questo, al
## rientro il login sarebbe da rifare pur essendo gia' concluso sul server.
func _save_pending() -> void:
	var f := FileAccess.open(PENDING_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"state": _oauth_state,
		"started": Time.get_unix_time_from_system(),
	}))
	f.close()


func _forget_pending() -> void:
	_oauth_state = ""
	_poll_inflight = false
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(PENDING_PATH.get_file()):
		dir.remove(PENDING_PATH.get_file())


## Riprende un consenso salvato, se non e' scaduto. Come "restore": un esito
## negativo non e' colpa di un gesto appena fatto dal giocatore, quindi non
## mostra errori e si limita a lasciarlo sulla schermata di login.
func _resume_pending_login() -> bool:
	if not FileAccess.file_exists(PENDING_PATH):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PENDING_PATH))
	var saved: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	var state := String(saved.get("state", ""))
	var age := Time.get_unix_time_from_system() - float(saved.get("started", 0.0))
	if state == "" or age < 0.0 or age > OAUTH_TTL:
		_forget_pending()
		return false
	_oauth_state = state
	_login_source = "restore"
	_restoring = true
	_pending = true
	_deadline = _now() + (OAUTH_TTL - age)
	_poll_at = 0.0
	print("[Auth] login Google in sospeso: ritiro la sessione")
	return true


static func email_looks_valid(email: String) -> bool:
	var e := email.strip_edges()
	var at := e.find("@")
	return at > 0 and e.find(".", at) > at + 1 and not e.contains(" ") and not e.ends_with(".")


## "" se la password va bene, altrimenti il messaggio da mostrare.
static func password_problem(password: String) -> String:
	if password.length() < 8:
		return String(TranslationServer.translate("LOGIN_PASSWORD_TOO_SHORT"))
	return ""


func _save_refresh_token() -> void:
	if _refresh_token == "":
		return
	var f := FileAccess.open(TOKEN_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(_refresh_token)
		f.close()
