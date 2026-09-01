class_name GoogleOAuth
extends RefCounted

## Scambio del code OAuth con Google, lato master. Il client cattura il code sul
## loopback (net/auth.gd) e lo inoltra al master, che qui lo scambia per un
## id_token usando GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET (env, /etc/autochess/env).
##
## L'id_token arriva direttamente da Google su TLS e non passa mai per il client:
## la firma NON viene verificata (nessuna JWKS), si validano solo i claim
## aud/iss/exp/sub. Vedi SELFHOST_PLAN.md D0.4.

const TOKEN_ENDPOINT := "https://oauth2.googleapis.com/token"
const VALID_ISS := ["accounts.google.com", "https://accounts.google.com"]


static func is_configured() -> bool:
	return OS.get_environment("GOOGLE_CLIENT_ID") != "" \
		and OS.get_environment("GOOGLE_CLIENT_SECRET") != ""


## cb.call(ok: bool, claims: Dictionary) -> {sub, email, name} in caso di successo,
## {"reason": "..."} altrimenti.
static func exchange_code(owner: Node, code: String, verifier: String, redirect_uri: String, cb: Callable) -> void:
	if not is_configured() or owner == null or not is_instance_valid(owner):
		cb.call(false, {"reason": "oauth_not_configured"})
		return
	# Il redirect_uri deve essere loopback: senza questo vincolo il master
	# diventa un oracolo di scambio code per redirect arbitrari.
	if not (redirect_uri.begins_with("http://127.0.0.1:") and redirect_uri.ends_with("/callback")):
		cb.call(false, {"reason": "bad_redirect"})
		return
	if code == "" or verifier == "":
		cb.call(false, {"reason": "missing_code"})
		return

	var client_id := OS.get_environment("GOOGLE_CLIENT_ID")
	var form := "grant_type=authorization_code"
	form += "&code=" + code.uri_encode()
	form += "&code_verifier=" + verifier.uri_encode()
	form += "&redirect_uri=" + redirect_uri.uri_encode()
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
