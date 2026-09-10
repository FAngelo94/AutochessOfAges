class_name OAuthPending
extends RefCounted

## Login Google in sospeso, lato master. Socket-free e testabile in-process
## (tests/net_smoke.gd), come Matchmaker: il pezzo che parla HTTP e' OAuthHttp.
##
## Perche' esiste. Il flusso loopback (RFC 8252) e' un flusso DESKTOP e su
## Android non puo' funzionare: appena si apre il browser l'activity di Godot va
## in pausa e il main loop si ferma, quindi nessun TCPServer dentro l'app puo'
## accettare il redirect di Google. Qui il redirect va invece su
## https://<host>/oauth/cb -> Caddy -> master: lo scambio del code avviene sul
## server MENTRE il gioco e' in pausa, e il client ritira il risultato quando
## torna in primo piano (AUTH_GOOGLE_POLL).
##
## Il `state` e' quindi il portatore della sessione: 32 byte da Crypto (mai
## randi()), a uso singolo, con TTL breve. La coppia PKCE la genera il master —
## nel flusso loopback serviva al client per legare a se' il code, qui chi apre
## la richiesta e chi la chiude sono lo stesso processo.

## Vita di uno state: copre il tempo del consenso su accounts.google.com.
const TTL_SECONDS := 600.0
## Tetto agli state vivi: un client che spamma AUTH_GOOGLE_BEGIN non deve poter
## far crescere il dizionario senza limite. Oltre il tetto cade il piu' vecchio.
const MAX_ENTRIES := 512

const STATUS_WAITING := "waiting"    # consenso non ancora concluso
const STATUS_READY := "ready"        # bundle pronto da ritirare
const STATUS_FAILED := "failed"      # scambio fallito, con motivo
const STATUS_UNKNOWN := "unknown"    # state mai visto, gia' ritirato o scaduto

# state -> {verifier, created, status, bundle, reason}
var _entries: Dictionary = {}


## Apre un login: restituisce {state, verifier, challenge}. Il chiamante manda
## al client solo lo state (e l'URL di consenso costruito col challenge): il
## verifier non lascia mai il master.
func begin(now: float) -> Dictionary:
	prune(now)
	if _entries.size() >= MAX_ENTRIES:
		_drop_oldest()
	var state := _random_hex(32)
	var verifier := _random_verifier()
	_entries[state] = {
		"verifier": verifier,
		"created": now,
		"status": STATUS_WAITING,
		"bundle": {},
		"reason": "",
	}
	return {
		"state": state,
		"verifier": verifier,
		"challenge": challenge_for(verifier),
	}


## Verifier di uno state ancora in attesa, "" se sconosciuto/scaduto/gia' risolto.
## Lo usa il callback HTTP per completare lo scambio con Google.
func verifier_for(state: String, now: float) -> String:
	var e: Dictionary = _entries.get(state, {})
	if e.is_empty() or _expired(e, now) or String(e["status"]) != STATUS_WAITING:
		return ""
	return String(e["verifier"])


## Deposita il bundle di sessione: da qui il client puo' ritirarlo con take().
func resolve(state: String, bundle: Dictionary, now: float) -> bool:
	var e: Dictionary = _entries.get(state, {})
	if e.is_empty() or _expired(e, now):
		return false
	e["status"] = STATUS_READY
	e["bundle"] = bundle
	e["verifier"] = ""   # servito, non serve piu' tenerlo in memoria
	return true


func fail(state: String, reason: String, now: float) -> bool:
	var e: Dictionary = _entries.get(state, {})
	if e.is_empty() or _expired(e, now):
		return false
	e["status"] = STATUS_FAILED
	e["reason"] = reason
	e["verifier"] = ""
	return true


## Ritiro da parte del client. {status, bundle, reason}. A uso singolo: un esito
## (ready o failed) viene consegnato una volta sola e poi lo state sparisce.
## Uno state in attesa resta, cosi' il client puo' richiedere ancora.
func take(state: String, now: float) -> Dictionary:
	prune(now)
	var e: Dictionary = _entries.get(state, {})
	if e.is_empty():
		return {"status": STATUS_UNKNOWN, "bundle": {}, "reason": "expired"}
	var status := String(e["status"])
	if status == STATUS_WAITING:
		return {"status": STATUS_WAITING, "bundle": {}, "reason": ""}
	_entries.erase(state)
	return {"status": status, "bundle": e["bundle"], "reason": String(e["reason"])}


func prune(now: float) -> void:
	for state in _entries.keys():
		if _expired(_entries[state], now):
			_entries.erase(state)


func size() -> int:
	return _entries.size()


## Challenge PKCE (S256) di un verifier. Statica: la usa anche chi costruisce
## l'URL di consenso.
static func challenge_for(verifier: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(verifier.to_utf8_buffer())
	return base64url(ctx.finish())


static func base64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")


func _expired(entry: Dictionary, now: float) -> bool:
	return now - float(entry["created"]) > TTL_SECONDS


func _drop_oldest() -> void:
	var oldest := ""
	var oldest_at := INF
	for state in _entries.keys():
		var created := float(_entries[state]["created"])
		if created < oldest_at:
			oldest_at = created
			oldest = state
	if oldest != "":
		_entries.erase(oldest)


static func _random_hex(bytes: int) -> String:
	return Crypto.new().generate_random_bytes(bytes).hex_encode()


## Verifier PKCE: 43..128 caratteri dell'alfabeto unreserved (RFC 7636). 48 byte
## in base64url danno 64 caratteri, dentro l'intervallo.
static func _random_verifier() -> String:
	return base64url(Crypto.new().generate_random_bytes(48))
