class_name SessionToken
extends RefCounted

## Token di SESSIONE emesso dal master dopo un login Google riuscito (o un
## refresh). Il client lo presenta in HELLO come
## `access_token` e il master lo verifica con SessionVerifier (iniettato in
## Matchmaker). Firma HMAC-SHA256, stesso schema di server/match_token.gd.
##
## Segreto: variabile d'ambiente SESSION_TOKEN_SECRET (deploy: /etc/autochess/env).
## Distinto da MATCH_TOKEN_SECRET: ruoli e durate diversi. In assenza si usa un
## segreto di sviluppo — NON sicuro in produzione.
##
## Formato: "<uid>|<username_b64url>|<exp>|<sig_base64>"
## L'username e' base64url perche' puo' contenere '|'; uid ed exp non lo contengono.

const DEFAULT_TTL := 604800  # 7 giorni


static func mint(uid: String, username: String, now_unix: int = -1, ttl: int = DEFAULT_TTL) -> String:
	var issued := now_unix if now_unix >= 0 else int(Time.get_unix_time_from_system())
	var exp := issued + ttl
	var name_enc := _b64url(username.to_utf8_buffer())
	var payload := "%s|%s|%d" % [uid, name_enc, exp]
	return "%s|%s" % [payload, _sign(payload)]


## Restituisce {sub, name, exp} se la firma e' valida e il token non e' scaduto;
## {} altrimenti. La chiave `sub` (non `uid`) e `name` combaciano con cio' che
## Matchmaker._on_hello si aspetta dal verificatore.
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
	var name := _b64url_decode(parts[1]).get_string_from_utf8()
	return {"sub": parts[0], "name": name, "exp": exp}


static func _secret() -> String:
	var env := OS.get_environment("SESSION_TOKEN_SECRET")
	return env if env != "" else "dev-insecure-session-token-secret"


static func _sign(payload: String) -> String:
	var ctx := HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, _secret().to_utf8_buffer())
	ctx.update(payload.to_utf8_buffer())
	return Marshalls.raw_to_base64(ctx.finish())


static func _b64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")


static func _b64url_decode(s: String) -> PackedByteArray:
	var t := s.replace("-", "+").replace("_", "/")
	while t.length() % 4 != 0:
		t += "="
	return Marshalls.base64_to_raw(t)
