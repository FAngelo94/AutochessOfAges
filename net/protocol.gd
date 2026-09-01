class_name Protocol
extends RefCounted

## Protocollo di rete condiviso client / master / worker (MULTIPLAYER_PLAN.md M4,
## Appendice A). Ogni messaggio e' un Dictionary con la chiave `t` (tipo).
##
## Codifica: var_to_bytes / bytes_to_var — non JSON. Entrambi i lati sono Godot
## 4.7 e var_to_bytes preserva Vector2i nativamente (serve all'event log del
## combattimento). decode() non decodifica mai oggetti: accetta solo dati puri.

const PROTOCOL_VERSION := 2
const MAX_PACKET_BYTES := 262144        # 256 KiB: pacchetti piu' grandi -> scartati

## Chiave del tipo di messaggio.
const KEY_TYPE := "t"

# --- Client -> Master (autenticazione, prima di HELLO) ------------------------
## Lo scambio del code OAuth lo fa il master (tiene GOOGLE_CLIENT_SECRET): il
## client cattura il code sul loopback e lo inoltra qui. Vedi net/auth.gd e
## server/account_service.gd.
const AUTH_GOOGLE := "AUTH_GOOGLE"      # {code, code_verifier, redirect_uri}
const AUTH_REFRESH := "AUTH_REFRESH"    # {refresh_token}
const PROFILE_SET := "PROFILE_SET"      # {session_token, favourite_origin, favourite_hero}
const DELETE_ACCOUNT := "DELETE_ACCOUNT"# {session_token} — cancellazione GDPR / requisito Play Store

# --- Client -> Master ---------------------------------------------------------
const HELLO := "HELLO"                  # {protocol_version, access_token}
const QUEUE_JOIN := "QUEUE_JOIN"        # {hero_id}
const QUEUE_LEAVE := "QUEUE_LEAVE"      # {}

# --- Master -> Client --------------------------------------------------------
const AUTH_OK := "AUTH_OK"              # {session_token, refresh_token, user_id, username, profile, stats, owned_civs}
const AUTH_FAIL := "AUTH_FAIL"          # {reason}
const PROFILE_OK := "PROFILE_OK"        # {}
const ACCOUNT_DELETED := "ACCOUNT_DELETED" # {}
const WELCOME := "WELCOME"              # {user_id, username, stats}
const REJECTED := "REJECTED"            # {reason: version|auth|banned|oversize}
const QUEUE_UPDATE := "QUEUE_UPDATE"    # {players, seconds_left}
const MATCH_ASSIGNED := "MATCH_ASSIGNED"# {match_id, worker_path, match_token, seed}

# --- Master <-> Worker (canale di controllo interno, non esposto da Caddy) ----
const SPAWN_MATCH := "SPAWN_MATCH"      # {match_id, seed, slots[], ranked, worker_path}
const SPAWN_ACK := "SPAWN_ACK"         # {match_id, ok}

# --- Client -> Worker -------------------------------------------------------
const JOIN := "JOIN"                    # {match_id, match_token}
const CMD_BUY := "CMD_BUY"              # {slot}
const CMD_SELL := "CMD_SELL"            # {uid}
const CMD_REROLL := "CMD_REROLL"        # {}
const CMD_BUY_XP := "CMD_BUY_XP"        # {}
const CMD_MOVE_BOARD := "CMD_MOVE_BOARD"# {uid, cell: Vector2i}
const CMD_MOVE_BENCH := "CMD_MOVE_BENCH"# {uid, slot}
const READY := "READY"                  # {}
const SPECTATE_REQUEST := "SPECTATE_REQUEST" # {player_index}
const SURRENDER := "SURRENDER"          # {}

# --- Worker -> Client -------------------------------------------------------
const MATCH_STATE := "MATCH_STATE"          # MatchState.to_dict(for_index)
const ROUND_STARTED := "ROUND_STARTED"      # {stage, round_index, prep_seconds}
const COMBAT := "COMBAT"                    # {combat, team, opponent_hero_id}
const ROUND_CONCLUDED := "ROUND_CONCLUDED"  # {results[]}
const COMMAND_REJECTED := "COMMAND_REJECTED"# {reason} — non disconnette
const MATCH_FINISHED := "MATCH_FINISHED"    # {standings[]}
const SPECTATE_DATA := "SPECTATE_DATA"      # {combat, player_index}


static func encode(msg: Dictionary) -> PackedByteArray:
	return var_to_bytes(msg)


## Decodifica un pacchetto. Restituisce {} su qualunque anomalia: pacchetto
## vuoto o oltre MAX_PACKET_BYTES, dato non decodificabile, o risultato che non
## e' un Dictionary. Non solleva mai un errore: un pacchetto malformato va
## ignorato, non deve far cadere il server.
static func decode(bytes: PackedByteArray) -> Dictionary:
	# < 4 byte non e' nemmeno un header var_to_bytes valido: evita anche il
	# messaggio d'errore rumoroso di bytes_to_var.
	if bytes.size() < 4 or bytes.size() > MAX_PACKET_BYTES:
		return {}
	var value: Variant = bytes_to_var(bytes)  # niente allow_objects: solo dati puri
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	return value


## Costruisce un messaggio col tipo indicato piu' i campi dati.
static func make(t: String, fields: Dictionary = {}) -> Dictionary:
	var msg: Dictionary = fields.duplicate()
	msg[KEY_TYPE] = t
	return msg


static func message_type(msg: Dictionary) -> String:
	return String(msg.get(KEY_TYPE, ""))
