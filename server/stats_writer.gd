class_name StatsWriter
extends RefCounted

## Persistenza dei risultati di partita su Supabase (MULTIPLAYER_PLAN.md M5, M1).
##
## SOLO il server scrive `match_history` e `player_stats`, con la SERVICE_ROLE key
## (bypassa la RLS). Il client non ha alcuna policy di scrittura su quelle tabelle.
##
## Config via ambiente (deploy: /etc/autochess/env, mode 0600):
##   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
## Assenti -> no-op loggato: i test headless e lo sviluppo locale non richiedono
## Supabase.
##
## --- "Transazione" ---
## PostgREST non offre transazioni multi-tabella dal client REST. Per scrivere
## `match_history` + N righe `player_stats` atomicamente si usa UNA funzione
## Postgres `public.record_match_result(payload jsonb)` (SECURITY DEFINER),
## invocata con POST /rest/v1/rpc/record_match_result: gira interamente
## server-side in una singola transazione implicita. La definizione della
## funzione va aggiunta a db/migrations (M1); la firma del payload e' qui sotto.
## Se la RPC non esiste ancora, _fallback_insert() inserisce almeno match_history
## (non atomico, ma nessuna perdita di dati di cronologia).

const RPC_PATH := "/rest/v1/rpc/record_match_result"
const HISTORY_PATH := "/rest/v1/match_history"


## standings: [{player_index, uid, placement, hp, hero_id, display_name, is_bot}]
static func write_match(owner: Node, match_id: String, seed_value: int, ranked: bool, standings: Array) -> void:
	var url := OS.get_environment("SUPABASE_URL").rstrip("/")
	var key := OS.get_environment("SUPABASE_SERVICE_ROLE_KEY")
	if url == "" or key == "":
		print("StatsWriter: SUPABASE_URL/SERVICE_ROLE_KEY assenti — no-op. ",
			"match=%s ranked=%s standings=%s" % [match_id, ranked, _human_results(standings)])
		return
	if owner == null or not is_instance_valid(owner):
		push_warning("StatsWriter: nessun Node owner per HTTPRequest — scrittura saltata (match=%s)" % match_id)
		return

	var payload := {
		"p_match_id": match_id,
		"p_seed": seed_value,
		"p_ranked": ranked,
		"p_results": _human_results(standings),
	}
	var headers := PackedStringArray([
		"apikey: " + key,
		"Authorization: Bearer " + key,
		"Content-Type: application/json",
		"Prefer: return=minimal",
	])

	var http := HTTPRequest.new()
	owner.add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		if code >= 200 and code < 300:
			print("StatsWriter: match %s registrato (RPC)" % match_id)
		else:
			push_warning("StatsWriter: RPC fallita (result=%d code=%d) — fallback match_history. %s" % [
				result, code, body.get_string_from_utf8()])
			_fallback_insert(owner, url, key, match_id, seed_value, ranked, standings)
		http.queue_free())
	var err := http.request(url + RPC_PATH, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		push_warning("StatsWriter: HTTPRequest.request err %d" % err)
		http.queue_free()


static func _fallback_insert(owner: Node, url: String, key: String, match_id: String,
		seed_value: int, ranked: bool, standings: Array) -> void:
	var row := {
		"seed": seed_value,
		"ranked": ranked,
		"ended_at": Time.get_datetime_string_from_system(true),
		"results": _human_results(standings),
	}
	var headers := PackedStringArray([
		"apikey: " + key,
		"Authorization: Bearer " + key,
		"Content-Type: application/json",
		"Prefer: return=minimal",
	])
	var http := HTTPRequest.new()
	owner.add_child(http)
	http.request_completed.connect(func(_r: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
		print("StatsWriter: fallback match_history code=%d" % code)
		http.queue_free())
	var err := http.request(url + HISTORY_PATH, headers, HTTPClient.METHOD_POST, JSON.stringify(row))
	if err != OK:
		http.queue_free()


## Solo i posti umani (uid non vuoto) finiscono nelle statistiche: i bot non
## hanno un profilo Supabase.
static func _human_results(standings: Array) -> Array:
	var out: Array = []
	for s in standings:
		if String(s.get("uid", "")) == "":
			continue
		out.append({
			"profile_id": s.get("uid", ""),
			"placement": int(s.get("placement", 0)),
			"hp": int(s.get("hp", 0)),
			"hero_id": s.get("hero_id", ""),
			"top4": int(s.get("placement", 9)) <= 4,
			"won": int(s.get("placement", 9)) == 1,
		})
	return out
