class_name SupabaseClient
extends RefCounted

## Wrapper minimale su Supabase Auth REST + PostgREST, basato su HTTPRequest.
##
## Non è un Node: per fare richieste ha bisogno di un "owner" Node vivo
## nell'albero (tipicamente l'autoload Auth), a cui aggancia gli HTTPRequest
## come figli temporanei. Ogni HTTPRequest viene liberato appena la richiesta
## si conclude.
##
## URL e anon key si leggono da data/backend.json. Con valori segnaposto
## is_configured() torna false e nessun chiamante deve procedere.

const CONFIG_PATH := "res://data/backend.json"

var supabase_url: String = ""
var anon_key: String = ""

var _owner: Node


func _init(owner: Node) -> void:
	_owner = owner
	_load_config()


func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var text := FileAccess.get_file_as_string(CONFIG_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	supabase_url = String(parsed.get("supabase_url", "")).rstrip("/")
	anon_key = String(parsed.get("anon_key", ""))


## Vero solo se data/backend.json ha valori reali (non i segnaposto).
func is_configured() -> bool:
	if not supabase_url.begins_with("http"):
		return false
	if supabase_url.contains("YOUR-PROJECT-REF"):
		return false
	if anon_key.is_empty() or anon_key == "REPLACE_WITH_ANON_KEY":
		return false
	return true


# --------------------------------------------------------------------------
# Auth REST
# --------------------------------------------------------------------------

## Scambia il code PKCE + verifier per access_token + refresh_token.
## cb.call(success: bool, data: Dictionary)
func token_from_pkce(code: String, verifier: String, cb: Callable) -> void:
	var body := JSON.stringify({"auth_code": code, "code_verifier": verifier})
	_request("%s/auth/v1/token?grant_type=pkce" % supabase_url,
		HTTPClient.METHOD_POST, _auth_headers(), body, cb)


## Rinnova la sessione a partire dal refresh token salvato.
## cb.call(success: bool, data: Dictionary)
func token_from_refresh(refresh_token: String, cb: Callable) -> void:
	var body := JSON.stringify({"refresh_token": refresh_token})
	_request("%s/auth/v1/token?grant_type=refresh_token" % supabase_url,
		HTTPClient.METHOD_POST, _auth_headers(), body, cb)


# --------------------------------------------------------------------------
# PostgREST — tabella profiles
# --------------------------------------------------------------------------

## Legge la riga del profilo dell'utente. cb.call(success: bool, row: Dictionary)
func get_profile(access_token: String, uid: String, cb: Callable) -> void:
	var url := "%s/rest/v1/profiles?id=eq.%s&select=*" % [supabase_url, uid]
	_request(url, HTTPClient.METHOD_GET, _rest_headers(access_token), "",
		func(ok: bool, data: Variant) -> void:
			if ok and data is Array and (data as Array).size() > 0:
				cb.call(true, (data as Array)[0])
			else:
				cb.call(false, {}))


## Aggiorna campi del profilo. cb.call(success: bool, row: Dictionary)
func update_profile(access_token: String, uid: String, fields: Dictionary, cb: Callable) -> void:
	var url := "%s/rest/v1/profiles?id=eq.%s" % [supabase_url, uid]
	var headers := _rest_headers(access_token)
	headers.append("Prefer: return=representation")
	_request(url, HTTPClient.METHOD_PATCH, headers, JSON.stringify(fields),
		func(ok: bool, data: Variant) -> void:
			if ok and data is Array and (data as Array).size() > 0:
				cb.call(true, (data as Array)[0])
			else:
				cb.call(ok, {}))


# --------------------------------------------------------------------------

func _auth_headers() -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"apikey: %s" % anon_key,
	])


func _rest_headers(access_token: String) -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"apikey: %s" % anon_key,
		"Authorization: Bearer %s" % access_token,
	])


## Esegue una singola richiesta HTTP con un HTTPRequest usa-e-getta.
## cb riceve (success: bool, parsed_json: Variant). parsed_json è {} se il
## corpo non è JSON valido.
func _request(url: String, method: int, headers: PackedStringArray, body: String, cb: Callable) -> void:
	if _owner == null or not is_instance_valid(_owner) or not _owner.is_inside_tree():
		cb.call(false, {})
		return
	var http := HTTPRequest.new()
	_owner.add_child(http)
	http.request_completed.connect(
		func(_result: int, code: int, _rh: PackedStringArray, response_body: PackedByteArray) -> void:
			var parsed: Variant = JSON.parse_string(response_body.get_string_from_utf8())
			if parsed == null:
				parsed = {}
			var success := _result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
			cb.call(success, parsed)
			http.queue_free())
	var err := http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		cb.call(false, {})
