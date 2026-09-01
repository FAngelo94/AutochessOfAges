class_name AccountService
extends RefCounted

## Orchestrazione del login, lato master (SELFHOST_PLAN.md D4.4). Chiamato da
## master_server.gd alla ricezione di AUTH_GOOGLE / AUTH_REFRESH.
##
## login_google:  GoogleOAuth.exchange_code -> DbClient.upsert_google_account
##                -> SessionToken.mint -> refresh opaco -> DbClient.store_refresh_token
## refresh:       sha256(refresh) -> DbClient.redeem_refresh_token (rotazione)
##                -> SessionToken.mint -> nuovo refresh -> store
##
## Il refresh token e' OPACO (32 byte casuali, esadecimale). Nel DB va solo il
## suo sha256: un dump non permette di impersonare nessuno.

const REFRESH_TTL_DAYS := 7


## cb.call(ok: bool, bundle: Dictionary)
## bundle = {session_token, refresh_token, user_id, username, profile, stats, owned_civs}
static func login_google(owner: Node, code: String, verifier: String, redirect_uri: String, cb: Callable) -> void:
	GoogleOAuth.exchange_code(owner, code, verifier, redirect_uri, func(ok: bool, claims: Dictionary) -> void:
		if not ok:
			cb.call(false, {"reason": String(claims.get("reason", "google"))})
			return
		DbClient.upsert_google_account(owner, claims.sub, claims.email, claims.name, func(ok2: bool, row: Dictionary) -> void:
			if not ok2:
				cb.call(false, {"reason": "db"})
				return
			_issue_session(owner, row, cb)))


## cb.call(ok: bool, bundle: Dictionary)
static func refresh(owner: Node, refresh_token: String, cb: Callable) -> void:
	if refresh_token == "":
		cb.call(false, {"reason": "missing_token"})
		return
	DbClient.redeem_refresh_token(owner, refresh_token.sha256_text(), func(ok: bool, row: Dictionary) -> void:
		if not ok:
			cb.call(false, {"reason": "invalid_refresh"})
			return
		_issue_session(owner, row, cb))


static func _issue_session(owner: Node, row: Dictionary, cb: Callable) -> void:
	var uid := String(row.get("id", ""))
	var username := String(row.get("username", ""))
	if uid == "":
		cb.call(false, {"reason": "db"})
		return
	var refresh_token := _random_hex(32)
	DbClient.store_refresh_token(owner, uid, refresh_token.sha256_text(), REFRESH_TTL_DAYS, func(_stored: bool) -> void:
		cb.call(true, {
			"session_token": SessionToken.mint(uid, username),
			"refresh_token": refresh_token,
			"user_id": uid,
			"username": username,
			"profile": row.get("profile", {}),
			"stats": row.get("stats", {}),
			"owned_civs": row.get("owned_civs", []),
		}))


static func _random_hex(n_bytes: int) -> String:
	var raw := Crypto.new().generate_random_bytes(n_bytes)
	var s := ""
	for b in raw:
		s += "%02x" % b
	return s
