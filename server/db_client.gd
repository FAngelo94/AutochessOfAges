class_name DbClient
extends RefCounted

## Accesso ai dati per master e worker, via PostgREST sul loopback del VPS
## (127.0.0.1:3000, mai esposto da Caddy). Rimpiazza server/supabase_admin.gd.
##
## Non c'e' piu' service_role ne' anon key: PostgREST e' raggiungibile solo dai
## processi sulla stessa macchina, il ruolo Postgres `autochess_app` e' a
## privilegio minimo (vedi db/migrations/0001_initial.sql). Nessun header di
## autenticazione.
##
## Config via ambiente: DB_API_URL (es. http://127.0.0.1:3000). Assente ->
## is_configured() == false: i chiamanti degradano a no-op (test headless,
## sviluppo locale senza PostgREST).
##
## Ogni funzione e' statica e prende un `owner: Node` vivo nell'albero a cui
## agganciare un HTTPRequest usa-e-getta; `cb.call(ok: bool, dati)` alla fine.

const RPC_UPSERT_ACCOUNT := "/rpc/upsert_google_account"
const RPC_STORE_REFRESH := "/rpc/store_refresh_token"
const RPC_REDEEM_REFRESH := "/rpc/redeem_refresh_token"
const RPC_DELETE_ACCOUNT := "/rpc/delete_account"
const OWNED_CIVS_PATH := "/owned_civs"
const PROFILES_PATH := "/profiles"


static func is_configured() -> bool:
	return OS.get_environment("DB_API_URL") != ""


static func _base_url() -> String:
	return OS.get_environment("DB_API_URL").rstrip("/")


# --------------------------------------------------------------------------
# Letture
# --------------------------------------------------------------------------

## cb.call(ok: bool, civ_ids: PackedStringArray). ok=false = lettura fallita
## (il chiamante non deve declassare in caso di errore di rete).
static func fetch_owned_civs(owner: Node, uid: String, cb: Callable) -> void:
	var url := "%s%s?select=civ_id&profile_id=eq.%s" % [_base_url(), OWNED_CIVS_PATH, uid]
	_request(owner, url, HTTPClient.METHOD_GET, [], "", func(ok: bool, data: Variant) -> void:
		var civs := PackedStringArray()
		if ok and data is Array:
			for row in data:
				if row is Dictionary and row.has("civ_id"):
					civs.append(String(row["civ_id"]))
		cb.call(ok, civs))


# --------------------------------------------------------------------------
# RPC account / sessioni
# --------------------------------------------------------------------------

## upsert_google_account(p_sub, p_email, p_name) -> jsonb con
## {id, username, profile, stats, owned_civs}. cb.call(ok: bool, row: Dictionary)
static func upsert_google_account(owner: Node, sub: String, email: String, name: String, cb: Callable) -> void:
	var body := JSON.stringify({"p_sub": sub, "p_email": email, "p_name": name})
	_rpc(owner, RPC_UPSERT_ACCOUNT, body, func(ok: bool, data: Variant) -> void:
		cb.call(ok and data is Dictionary, data if data is Dictionary else {}))


## store_refresh_token(p_profile, p_hash, p_ttl_days) -> void. cb.call(ok: bool)
static func store_refresh_token(owner: Node, uid: String, token_hash: String, ttl_days: int, cb: Callable) -> void:
	var body := JSON.stringify({"p_profile": uid, "p_hash": token_hash, "p_ttl_days": ttl_days})
	_rpc(owner, RPC_STORE_REFRESH, body, func(ok: bool, _d: Variant) -> void: cb.call(ok))


## redeem_refresh_token(p_hash) -> jsonb bundle, oppure null se assente/scaduto.
## cb.call(ok: bool, row: Dictionary). ok=false anche quando il token non c'e'.
static func redeem_refresh_token(owner: Node, token_hash: String, cb: Callable) -> void:
	var body := JSON.stringify({"p_hash": token_hash})
	_rpc(owner, RPC_REDEEM_REFRESH, body, func(ok: bool, data: Variant) -> void:
		cb.call(ok and data is Dictionary, data if data is Dictionary else {}))


## delete_account(p_id) -> void. Cancella profilo + (cascade) stats/civs/sessioni.
## cb.call(ok: bool)
static func delete_account(owner: Node, uid: String, cb: Callable) -> void:
	_rpc(owner, RPC_DELETE_ACCOUNT, JSON.stringify({"p_id": uid}),
		func(ok: bool, _d: Variant) -> void: cb.call(ok))


## PATCH profiles: aggiorna solo favourite_origin / favourite_hero. cb.call(ok: bool)
static func update_preferences(owner: Node, uid: String, fields: Dictionary, cb: Callable) -> void:
	var url := "%s%s?id=eq.%s" % [_base_url(), PROFILES_PATH, uid]
	var headers := ["Content-Type: application/json", "Prefer: return=minimal"]
	_request(owner, url, HTTPClient.METHOD_PATCH, headers, JSON.stringify(fields),
		func(ok: bool, _d: Variant) -> void: cb.call(ok))


# --------------------------------------------------------------------------

static func _rpc(owner: Node, path: String, body: String, cb: Callable) -> void:
	_request(owner, _base_url() + path, HTTPClient.METHOD_POST,
		["Content-Type: application/json"], body, cb)


## Esegue una richiesta con un HTTPRequest usa-e-getta. cb riceve
## (success: bool, parsed_json: Variant); parsed è null se il corpo è vuoto o non JSON.
static func _request(owner: Node, url: String, method: int, headers: Array, body: String, cb: Callable) -> void:
	if not is_configured() or owner == null or not is_instance_valid(owner) or not owner.is_inside_tree():
		cb.call(false, null)
		return
	var http := HTTPRequest.new()
	owner.add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _rh: PackedStringArray, response_body: PackedByteArray) -> void:
			var parsed: Variant = JSON.parse_string(response_body.get_string_from_utf8())
			var success := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
			if not success:
				push_warning("DbClient: %s -> result=%d code=%d" % [url, result, code])
			cb.call(success, parsed)
			http.queue_free())
	var err := http.request(url, PackedStringArray(headers), method, body)
	if err != OK:
		push_warning("DbClient: HTTPRequest.request err %d (%s)" % [err, url])
		http.queue_free()
		cb.call(false, null)
