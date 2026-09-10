class_name GoogleOAuth
extends RefCounted

## Consenso Google, lato master. Il master costruisce l'URL di consenso
## (build_auth_url), riceve il redirect su https://<host>/oauth/cb
## (server/oauth_http.gd) e scambia il code per un id_token qui, usando
## GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET (env, /etc/autochess/env).
##
## Il redirect NON e' piu' il loopback dentro l'app (RFC 8252): su Android
## l'app va in pausa appena si apre il browser e non puo' accettare niente.
## Passando dal server, lo scambio avviene mentre il gioco e' in background e il
## client ritira la sessione al rientro. Vedi server/oauth_pending.gd.
##
## Il client OAuth deve quindi essere di tipo "Web application", con
## GOOGLE_REDIRECT_URI fra gli "Authorized redirect URIs" (SETUP_DB.md §2).
##
## L'id_token arriva direttamente da Google su TLS e non passa mai per il client:
## la firma NON viene verificata (nessuna JWKS), si validano solo i claim
## aud/iss/exp/sub. Vedi SELFHOST_PLAN.md D0.4.

const AUTH_ENDPOINT := "https://accounts.google.com/o/oauth2/v2/auth"
const TOKEN_ENDPOINT := "https://oauth2.googleapis.com/token"
const SCOPE := "openid email profile"
const VALID_ISS := ["accounts.google.com", "https://accounts.google.com"]


static func is_configured() -> bool:
	return OS.get_environment("GOOGLE_CLIENT_ID") != "" \
		and OS.get_environment("GOOGLE_CLIENT_SECRET") != "" \
		and redirect_uri() != ""


## URI di redirect registrato su Google. Unico per tutte le piattaforme: e' il
## server a riceverlo, non l'app.
static func redirect_uri() -> String:
	return OS.get_environment("GOOGLE_REDIRECT_URI").strip_edges()


## URL di consenso da aprire nel browser dell'utente. `state` lega la risposta
## alla richiesta in sospeso (server/oauth_pending.gd).
static func build_auth_url(challenge: String, state: String) -> String:
	return "%s?client_id=%s&redirect_uri=%s&response_type=code&scope=%s&state=%s&code_challenge=%s&code_challenge_method=S256" % [
		AUTH_ENDPOINT,
		OS.get_environment("GOOGLE_CLIENT_ID").uri_encode(),
		redirect_uri().uri_encode(),
		SCOPE.uri_encode(),
		state.uri_encode(),
		challenge.uri_encode()]


## cb.call(ok: bool, claims: Dictionary) -> {sub, email, name} in caso di successo,
## {"reason": "..."} altrimenti.
static func exchange_code(owner: Node, code: String, verifier: String, cb: Callable) -> void:
	if not is_configured() or owner == null or not is_instance_valid(owner):
		cb.call(false, {"reason": "oauth_not_configured"})
		return
	if code == "" or verifier == "":
		cb.call(false, {"reason": "missing_code"})
		return

	var client_id := OS.get_environment("GOOGLE_CLIENT_ID")
	var form := "grant_type=authorization_code"
	form += "&code=" + code.uri_encode()
	form += "&code_verifier=" + verifier.uri_encode()
	form += "&redirect_uri=" + redirect_uri().uri_encode()
	form += "&client_id=" + client_id.uri_encode()
	form += "&client_secret=" + OS.get_environment("GOOGLE_CLIENT_SECRET").uri_encode()

	var http := HTTPRequest.new()
	owner.add_child(http)
	http.request_completed.connect(
		func(result: int, http_code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or http_code < 200 or http_code >= 300:
				push_warning("GoogleOAuth: token endpoint result=%d code=%d" % [result, http_code])
				cb.call(false, {"reason": "google_http"})
				return
			var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
			if not (parsed is Dictionary) or not (parsed as Dictionary).has("id_token"):
				cb.call(false, {"reason": "no_id_token"})
				return
			var claims := _decode_payload(String((parsed as Dictionary)["id_token"]))
			var check := _validate(claims, client_id)
			if check != "":
				push_warning("GoogleOAuth: id_token non valido (%s)" % check)
				cb.call(false, {"reason": check})
				return
			cb.call(true, {
				"sub": String(claims.get("sub", "")),
				"email": String(claims.get("email", "")),
				"name": String(claims.get("name", "")),
			}))
	var headers := PackedStringArray(["Content-Type: application/x-www-form-urlencoded"])
	if http.request(TOKEN_ENDPOINT, headers, HTTPClient.METHOD_POST, form) != OK:
		http.queue_free()
		cb.call(false, {"reason": "request_failed"})


static func _validate(claims: Dictionary, client_id: String) -> String:
	if claims.is_empty():
		return "malformed"
	if String(claims.get("aud", "")) != client_id:
		return "aud"
	if not VALID_ISS.has(String(claims.get("iss", ""))):
		return "iss"
	if String(claims.get("sub", "")) == "":
		return "sub"
	var exp := int(claims.get("exp", 0))
	if exp != 0 and int(Time.get_unix_time_from_system()) > exp:
		return "expired"
	return ""


static func _decode_payload(jwt: String) -> Dictionary:
	var parts := jwt.split(".")
	if parts.size() < 2:
		return {}
	var b64: String = parts[1].replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	var raw := Marshalls.base64_to_raw(b64)
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}
