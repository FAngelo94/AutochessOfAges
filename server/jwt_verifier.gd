class_name JwtVerifier
extends RefCounted

## Verifica dei JWT Supabase (RS256) contro la JWKS pubblica del progetto.
##
## La JWKS viene scaricata UNA volta all'avvio del master e cachata: non si
## chiama Supabase a ogni connessione. verify() e' poi puramente locale.
##
## --- RS256 in GDScript puro (nota di implementazione) ---
## Godot 4.7 ha Crypto/CryptoKey ma nessun parser JWT. L'approccio implementato:
##   1. split del JWT su '.', base64url-decode di header e payload;
##   2. dalla JWK (n, e in base64url) si ricostruisce una chiave pubblica RSA
##      codificando a mano un SubjectPublicKeyInfo DER, poi lo si avvolge in PEM
##      e lo si carica con CryptoKey.load_from_string(pem, true);
##   3. Crypto.verify(HASH_SHA256, sha256(signing_input), signature, key) —
##      RS256 e' RSASSA-PKCS1-v1_5 + SHA-256, cioe' esattamente cio' che
##      Crypto.verify fa con una chiave RSA.
## Questo e' il percorso reale ed e' attivo quando la JWKS e' stata caricata.
## Se la chiave non si carica (o la JWKS non e' disponibile: backend.json coi
## segnaposto) si degrada a _verify_claims_only(): decodifica e controlla exp e
## sub ma NON la firma. In quel caso is_signature_checked() torna false e il
## master logga un avviso all'avvio.
## Rollover delle chiavi: master_server.gd richiama init() ogni JWKS_REFRESH_SECONDS
## e _ingest_jwks() rimpiazza il set di chiavi. Un guard su _http evita richieste
## sovrapposte. TODO: caching su disco per sopravvivere a un riavvio con Supabase
## momentaneamente irraggiungibile.

var _crypto := Crypto.new()
var _keys: Dictionary = {}          # kid -> CryptoKey
var _keys_loaded := false
var _jwks_url := ""
var _http: HTTPRequest


func is_signature_checked() -> bool:
	return _keys_loaded and not _keys.is_empty()


## Scarica la JWKS. Richiede un Node vivo nell'albero per l'HTTPRequest.
## cb.call(ok: bool) opzionale.
func init(supabase_url: String, owner: Node, cb: Callable = Callable()) -> void:
	_jwks_url = "%s/auth/v1/.well-known/jwks.json" % supabase_url.rstrip("/")
	if owner == null or not is_instance_valid(owner):
		if cb.is_valid():
			cb.call(false)
		return
	if _http != null:
		# una richiesta è già in volo (refresh periodico chiamato troppo presto)
		if cb.is_valid():
			cb.call(is_signature_checked())
		return
	_http = HTTPRequest.new()
	owner.add_child(_http)
	_http.request_completed.connect(
		func(_result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			var ok := code == 200 and _ingest_jwks(body.get_string_from_utf8())
			_http.queue_free()
			_http = null
			if cb.is_valid():
				cb.call(ok))
	var err := _http.request(_jwks_url)
	if err != OK:
		_http.queue_free()
		_http = null
		if cb.is_valid():
			cb.call(false)


## Carica direttamente un insieme di chiavi JWK (usato dai test e come seam per
## un caching su disco).
func load_jwks_string(text: String) -> bool:
	return _ingest_jwks(text)


## Restituisce i claim decodificati ({sub, exp, ...}) se il token e' valido,
## {} altrimenti (firma errata, scaduto, malformato).
func verify(jwt: String) -> Dictionary:
	var parts := jwt.split(".")
	if parts.size() != 3:
		return {}
	var header: Variant = JSON.parse_string(_b64url_decode(parts[0]).get_string_from_utf8())
	var payload: Variant = JSON.parse_string(_b64url_decode(parts[1]).get_string_from_utf8())
	if typeof(header) != TYPE_DICTIONARY or typeof(payload) != TYPE_DICTIONARY:
		return {}
	if not _verify_claims_only(payload):
		return {}
	if is_signature_checked():
		if String(header.get("alg", "")) != "RS256":
			return {}
		var key: CryptoKey = _keys.get(String(header.get("kid", "")), null)
		if key == null and _keys.size() == 1:
			key = _keys.values()[0]
		if key == null:
			return {}
		var signing_input := (parts[0] + "." + parts[1]).to_utf8_buffer()
		var sig := _b64url_decode(parts[2])
		if not _crypto.verify(HashingContext.HASH_SHA256, _sha256(signing_input), sig, key):
			return {}
	return payload


# --------------------------------------------------------------------------

func _verify_claims_only(payload: Dictionary) -> bool:
	if String(payload.get("sub", "")) == "":
		return false
	var exp := int(payload.get("exp", 0))
	if exp != 0 and int(Time.get_unix_time_from_system()) > exp:
		return false
	return true


func _ingest_jwks(text: String) -> bool:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var keys: Variant = parsed.get("keys", [])
	if not (keys is Array):
		return false
	_keys.clear()
	for k in keys:
		if not (k is Dictionary):
			continue
		if String(k.get("kty", "")) != "RSA":
			continue
		var key := _rsa_key_from_jwk(String(k.get("n", "")), String(k.get("e", "")))
		if key != null:
			_keys[String(k.get("kid", ""))] = key
	_keys_loaded = true
	return not _keys.is_empty()


func _rsa_key_from_jwk(n_b64: String, e_b64: String) -> CryptoKey:
	var n := _b64url_decode(n_b64)
	var e := _b64url_decode(e_b64)
	if n.is_empty() or e.is_empty():
		return null
	var der := _spki_der(n, e)
	var pem := "-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n" % _wrap_pem(Marshalls.raw_to_base64(der))
	var key := CryptoKey.new()
	if key.load_from_string(pem, true) != OK:
		return null
	return key


# --- codifica DER minimale per SubjectPublicKeyInfo (RSA) ------------------

func _der_len(n: int) -> PackedByteArray:
	if n < 0x80:
		return PackedByteArray([n])
	var body := PackedByteArray()
	var x := n
	while x > 0:
		body.insert(0, x & 0xFF)
		x >>= 8
	var out := PackedByteArray([0x80 | body.size()])
	out.append_array(body)
	return out


func _der_tlv(tag: int, value: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([tag])
	out.append_array(_der_len(value.size()))
	out.append_array(value)
	return out


func _der_uint(raw: PackedByteArray) -> PackedByteArray:
	var b := raw.duplicate()
	while b.size() > 1 and b[0] == 0:
		b.remove_at(0)
	if not b.is_empty() and (b[0] & 0x80) != 0:
		var z := PackedByteArray([0x00])
		z.append_array(b)
		b = z
	return _der_tlv(0x02, b)


func _spki_der(n: PackedByteArray, e: PackedByteArray) -> PackedByteArray:
	var rsa_pub := PackedByteArray()
	rsa_pub.append_array(_der_uint(n))
	rsa_pub.append_array(_der_uint(e))
	rsa_pub = _der_tlv(0x30, rsa_pub)

	var alg := PackedByteArray([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
	alg.append_array(PackedByteArray([0x05, 0x00]))  # NULL parameters
	alg = _der_tlv(0x30, alg)

	var bit_value := PackedByteArray([0x00])          # 0 bit inutilizzati
	bit_value.append_array(rsa_pub)
	var bit_string := _der_tlv(0x03, bit_value)

	var spki := PackedByteArray()
	spki.append_array(alg)
	spki.append_array(bit_string)
	return _der_tlv(0x30, spki)


func _wrap_pem(b64: String) -> String:
	var lines := PackedStringArray()
	var i := 0
	while i < b64.length():
		lines.append(b64.substr(i, 64))
		i += 64
	return "\n".join(lines)


func _b64url_decode(s: String) -> PackedByteArray:
	var t := s.replace("-", "+").replace("_", "/")
	while t.length() % 4 != 0:
		t += "="
	return Marshalls.base64_to_raw(t)


func _sha256(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()
