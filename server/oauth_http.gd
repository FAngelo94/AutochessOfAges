class_name OAuthHttp
extends RefCounted

## Endpoint HTTP del redirect OAuth, lato master. Ascolta SOLO sul loopback:
## davanti c'e' Caddy (`handle /oauth/cb`), che fa TLS e proxy. E' l'unica cosa
## che il master serve in HTTP — tutto il resto e' WebSocket.
##
## Server minimale di proposito: legge la riga di richiesta e risponde con
## Connection: close, senza keep-alive.
##
## Due rotte, due forme diverse:
##   * GET  — il redirect di Google, che porta code e state in query e a cui si
##     risponde con una pagina HTML (`handler`).
##   * POST — il webhook di RevenueCat, che porta un JSON nel corpo e a cui si
##     risponde con un JSON (`post_handler`). La risposta puo' arrivare DOPO,
##     perche' registrare una donazione richiede un giro su PostgREST: il
##     webhook ritenta finche' non riceve un 2xx, quindi rispondere "ok" prima
##     di aver scritto la riga significherebbe perderla in silenzio.
##
## Non fa nulla di sensibile da solo: entrambi i gestori stanno nel master (vedi
## master_server.gd::_on_oauth_callback e ::_on_revenuecat_webhook).

const DEFAULT_PORT := 9010
## Una richiesta che non si completa entro questo tempo viene chiusa: un socket
## aperto e muto non deve poter occupare uno slot per sempre.
const READ_TIMEOUT := 5.0
## Quanto si aspetta il gestore asincrono di una POST prima di arrendersi e
## rispondere 500 (cosi' il mittente ritenta invece di credere di aver chiuso).
const HANDLER_TIMEOUT := 10.0
## Tetto ai byte letti da una singola richiesta prima di rispondere comunque.
const MAX_REQUEST_BYTES := 8192
## Il corpo di un webhook e' piccolo; un corpo piu' grosso di cosi' non e' roba
## nostra e non va bufferizzata.
const MAX_BODY_BYTES := 65536
const MAX_CONNECTIONS := 32

## Callable(path: String, query: Dictionary) -> String (HTML della risposta).
var handler: Callable
## Callable(path: String, headers: Dictionary, body: String, respond: Callable).
## `respond` va chiamata con (status: int, json_body: String), anche piu' tardi.
## Le chiavi di `headers` sono minuscole.
var post_handler: Callable

var _server: TCPServer = null
var _conns: Array = []      # [{peer, buf, opened, waiting, response}]


func listen(port: int) -> int:
	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		_server = null
	return err


func stop() -> void:
	for c in _conns:
		c.peer.disconnect_from_host()
	_conns.clear()
	if _server != null:
		_server.stop()
		_server = null


func poll(now: float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			break
		if _conns.size() >= MAX_CONNECTIONS:
			peer.disconnect_from_host()
			continue
		_conns.append({"peer": peer, "buf": "", "opened": now, "waiting": false, "response": null})

	for i in range(_conns.size() - 1, -1, -1):
		if _service(_conns[i], now):
			_conns[i].peer.disconnect_from_host()
			_conns.remove_at(i)


## true quando la connessione ha finito (risposta inviata, errore o timeout).
func _service(conn: Dictionary, now: float) -> bool:
	var peer: StreamPeerTCP = conn.peer
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return true

	# Richiesta gia' consegnata a un gestore asincrono: si aspetta la sua
	# risposta, con un tetto di tempo.
	if bool(conn.waiting):
		if conn.response != null:
			_send(peer, conn.response as Dictionary)
			return true
		if now - float(conn.opened) > HANDLER_TIMEOUT:
			_send(peer, _json_response(500, "{\"error\":\"timeout\"}"))
			return true
		return false

	var available := peer.get_available_bytes()
	if available > 0:
		conn.buf = String(conn.buf) + peer.get_utf8_string(available)

	var buf := String(conn.buf)
	# Le intestazioni finiscono con una riga vuota. Basta la prima riga per
	# sapere cosa serve, ma si aspetta la fine delle intestazioni per non
	# rispondere a meta' di una richiesta.
	if not buf.contains("\r\n\r\n"):
		if buf.length() < MAX_REQUEST_BYTES and now - float(conn.opened) < READ_TIMEOUT:
			return false
		if buf.strip_edges() == "":
			return true   # socket muto: si chiude senza rispondere

	var target := _request_target(buf)
	if target.is_empty():
		_send(peer, _html_response(error_page("Richiesta non valida.")))
		return true

	if String(target["method"]) == "POST":
		return _service_post(conn, peer, target, buf, now)

	var html := ""
	if handler.is_valid():
		html = String(handler.call(String(target["path"]), target["query"] as Dictionary))
	else:
		html = error_page("Servizio non disponibile.")
	_send(peer, _html_response(html))
	return true


## Il corpo di una POST arriva dopo le intestazioni e puo' essere spezzato su
## piu' pacchetti: finche' non ne sono arrivati Content-Length byte non si puo'
## chiamare il gestore, o gli si passerebbe mezzo JSON.
func _service_post(conn: Dictionary, peer: StreamPeerTCP, target: Dictionary,
		buf: String, now: float) -> bool:
	var headers: Dictionary = target["headers"]
	var declared := int(headers.get("content-length", "0"))
	if declared > MAX_BODY_BYTES:
		_send(peer, _json_response(413, "{\"error\":\"body_too_large\"}"))
		return true

	var split := buf.find("\r\n\r\n")
	var body := buf.substr(split + 4)
	if body.to_utf8_buffer().size() < declared:
		if now - float(conn.opened) < READ_TIMEOUT:
			return false
		_send(peer, _json_response(400, "{\"error\":\"incomplete_body\"}"))
		return true

	if not post_handler.is_valid():
		_send(peer, _json_response(404, "{\"error\":\"no_handler\"}"))
		return true

	conn.waiting = true
	# `conn` e' un Dictionary, quindi un riferimento: la risposta scritta dal
	# gestore quando avra' finito la ritrova il prossimo poll.
	post_handler.call(String(target["path"]), headers, body,
		func(status: int, json_body: String) -> void:
			conn.response = _json_response(status, json_body))
	return false


func _send(peer: StreamPeerTCP, response: Dictionary) -> void:
	var body: PackedByteArray = String(response.get("body", "")).to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\n" % [
		int(response.get("status", 200)),
		String(response.get("reason", "OK")),
		String(response.get("content_type", "text/html; charset=utf-8")),
	]
	head += "Cache-Control: no-store\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.size()
	peer.put_data(head.to_utf8_buffer())
	peer.put_data(body)


static func _html_response(html: String) -> Dictionary:
	return {"status": 200, "reason": "OK", "content_type": "text/html; charset=utf-8", "body": html}


static func _json_response(status: int, json_body: String) -> Dictionary:
	var reason := "OK"
	if status >= 500:
		reason = "Internal Server Error"
	elif status >= 400:
		reason = "Bad Request"
	elif status == 202:
		reason = "Accepted"
	return {"status": status, "reason": reason, "content_type": "application/json", "body": json_body}


## "GET /oauth/cb?code=x&state=y HTTP/1.1" -> {method, path, query, headers}.
## {} se malformata o con un metodo che non serviamo. Le chiavi di `headers`
## sono minuscole: i nomi delle intestazioni HTTP non distinguono maiuscole e
## chi scrive il gestore non deve indovinare come le ha scritte il mittente.
static func _request_target(request: String) -> Dictionary:
	var lines := request.split("\r\n")
	var parts := lines[0].split(" ")
	if parts.size() < 2:
		return {}
	var method: String = parts[0]
	if method != "GET" and method != "HEAD" and method != "POST":
		return {}
	var target: String = parts[1]
	var path := target
	var query: Dictionary = {}
	var q := target.find("?")
	if q != -1:
		path = target.substr(0, q)
		query = parse_query(target.substr(q + 1))

	var headers: Dictionary = {}
	for i in range(1, lines.size()):
		var line: String = lines[i]
		if line == "":
			break
		var colon := line.find(":")
		if colon > 0:
			headers[line.substr(0, colon).strip_edges().to_lower()] = line.substr(colon + 1).strip_edges()

	return {"method": method, "path": path, "query": query, "headers": headers}


static func parse_query(raw: String) -> Dictionary:
	var out: Dictionary = {}
	for pair in raw.split("&", false):
		var eq: int = pair.find("=")
		if eq <= 0:
			continue
		var key: String = pair.substr(0, eq).uri_decode()
		# `+` come spazio: Google non lo usa nei suoi parametri, ma la forma
		# application/x-www-form-urlencoded lo prevede.
		out[key] = pair.substr(eq + 1).replace("+", " ").uri_decode()
	return out


# --------------------------------------------------------------------------
# Pagine mostrate nel browser dopo il redirect
# --------------------------------------------------------------------------

## NIENTE pulsante "torna all'app", ed e' una scelta obbligata.
##
## C'era: un link `intent://...;action=MAIN;category=LAUNCHER;package=...` che
## avrebbe dovuto rimettere l'app in primo piano. Non poteva funzionare su
## nessun dispositivo. Chrome lancia un intent SOLO verso activity che
## dichiarano `android.intent.category.BROWSABLE` ("it indicates that the
## application is safe to open from the Browser"), e l'activity di Godot
## dichiara MAIN + DEFAULT + LAUNCHER. Il risultato era la pagina "Elemento non
## trovato" di Chrome: un vicolo cieco proprio nel momento in cui l'utente ha
## appena fatto il login.
##
## Riaggiungerlo richiede un intent-filter con BROWSABLE e uno schema custom nel
## manifest dell'app — non nel manifest di un plugin, dove sarebbe fuori posto.
## Finche' non c'e', la pagina si limita a dire di tornare all'app: il client
## ritira la sessione da solo quando torna in primo piano (AUTH_GOOGLE_POLL),
## quindi non si perde niente se non un tocco in meno.


static func success_page() -> String:
	return _page("Accesso completato",
		"<h2>Accesso completato &#10003;</h2>"
		+ "<p>Puoi chiudere questa pagina e tornare ad AoA: "
		+ "ti ritroverai gi&agrave; connesso.</p>")


static func error_page(message: String) -> String:
	return _page("Accesso non riuscito",
		"<h2>Accesso non riuscito</h2><p>%s</p><p>Riprova dall'app.</p>" % message.xml_escape())


static func _page(title: String, body: String) -> String:
	var head := "<!doctype html><html lang=\"it\"><head><meta charset=\"utf-8\">"
	head += "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
	head += "<title>%s</title>" % title
	head += "<style>body{font-family:system-ui,sans-serif;text-align:center;padding:3em 1.5em;"
	head += "background:#12121a;color:#eee}</style></head><body>"
	return head + body + "</body></html>"
