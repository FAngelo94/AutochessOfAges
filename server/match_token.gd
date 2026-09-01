class_name MatchToken
extends RefCounted

## Token a vita breve firmato dal master (HMAC-SHA256), consegnato al client in
## MATCH_ASSIGNED e presentato al worker in JOIN. Il worker verifica solo la
## firma HMAC col segreto condiviso, senza rifare la verifica del token di sessione.
##
## Segreto: variabile d'ambiente MATCH_TOKEN_SECRET (vedi deploy, /etc/autochess/env).
## In assenza si usa un segreto di sviluppo — NON sicuro in produzione.
##
## Formato: "<match_id>|<uid>|<exp>|<sig_base64>"  (i primi tre campi non
## contengono '|', match_id e uid sono generati dal server).

const DEFAULT_TTL := 120  # secondi: il tempo per passare dal master al worker


static func mint(match_id: String, uid: String, now_unix: int = -1, ttl: int = DEFAULT_TTL) -> String:
	var issued := now_unix if now_unix >= 0 else int(Time.get_unix_time_from_system())
	var exp := issued + ttl
	var payload := "%s|%s|%d" % [match_id, uid, exp]
	return "%s|%s" % [payload, _sign(payload)]


## Restituisce {match_id, uid, exp} se la firma e' valida e il token non e'
## scaduto; {} altrimenti.
static func verify(token: String, now_unix: int = -1) -> Dictionary:
	var parts := token.split("|")
	if parts.size() != 4:
		return {}
	var payload := "%s|%s|%s" % [parts[0], parts[1], parts[2]]
	if _sign(payload) != parts[3]:
		return {}
	var exp := int(parts[2])
	var now := now_unix if now_unix >= 0 else int(Time.get_unix_time_from_system())
	if now > exp:
		return {}
	return {"match_id": parts[0], "uid": parts[1], "exp": exp}


## --- Firma dei messaggi di controllo interni (master -> worker) --------------
##
## SPAWN_MATCH arriva al worker sullo stesso WebSocket dei client (una porta per
## worker, rotta Caddy /ws/wN): senza firma un client potrebbe forgiarne uno e
## far partire partite arbitrarie. Il worker verifica questo HMAC prima di creare
## un MatchRunner. Stesso segreto MATCH_TOKEN_SECRET del match_token.

## Stringa canonica e deterministica dei campi che contano di un SPAWN_MATCH.
static func _control_canonical(payload: Dictionary) -> String:
	var parts := PackedStringArray()
	parts.append(String(payload.get("match_id", "")))
	parts.append(str(int(payload.get("seed", 0))))
	parts.append("1" if bool(payload.get("ranked", false)) else "0")
	parts.append(String(payload.get("worker_path", "")))
	for s in payload.get("slots", []):
		parts.append("%d:%s:%s:%s" % [
			int(s.get("index", -1)), String(s.get("kind", "")),
			String(s.get("uid", "")), String(s.get("hero_id", "")),
		])
	return "".join(parts)


static func sign_control(payload: Dictionary) -> String:
	return _sign(_control_canonical(payload))


static func verify_control(payload: Dictionary, sig: String) -> bool:
	return sig != "" and _sign(_control_canonical(payload)) == sig


static func _secret() -> String:
	var env := OS.get_environment("MATCH_TOKEN_SECRET")
	return env if env != "" else "dev-insecure-match-token-secret"


static func _sign(payload: String) -> String:
	var ctx := HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, _secret().to_utf8_buffer())
	ctx.update(payload.to_utf8_buffer())
	return Marshalls.raw_to_base64(ctx.finish())
