class_name StatsWriter
extends RefCounted

## Persistenza dei risultati di partita, via PostgREST sul loopback del VPS
## (MULTIPLAYER_PLAN.md M5, M1). SOLO il server scrive `match_history` e
## `player_stats`: il ruolo Postgres `autochess_app` non ha `update` su
## player_stats, ce l'ha solo la funzione `record_match_result` (SECURITY DEFINER).
##
## Config via ambiente (deploy: /etc/autochess/env, mode 0600): DB_API_URL.
## Assente -> no-op loggato: i test headless e lo sviluppo locale non richiedono
## PostgREST.
##
## --- "Transazione" ---
## PostgREST non offre transazioni multi-tabella dal REST. Per scrivere
## `match_history` + N righe `player_stats` atomicamente si usa UNA funzione
## Postgres `public.record_match_result(...)` (SECURITY DEFINER), invocata con
## POST /rpc/record_match_result: gira interamente server-side in una singola
## transazione implicita. Se la RPC fallisce, _fallback_insert() inserisce almeno
## match_history (non atomico, ma nessuna perdita di dati di cronologia).
##
## --- Risposta della RPC ---
## record_match_result (db/migrations/0002_rank_mmr.sql) torna un jsonb con un
## oggetto per ogni umano aggiornato: {profile_id, mmr, delta, matches_played,
## wins, top4}. on_result, se passata, viene chiamata una volta per riga — la
## usa server/match_runner.gd per spedire un RANK_UPDATE al peer giusto. Niente
## "Prefer: return=minimal" sulla RPC: quello serve invece per _fallback_insert,
## dove il corpo della risposta non interessa a nessuno.

const RPC_PATH := "/rpc/record_match_result"
const HISTORY_PATH := "/match_history"


## standings: [{player_index, uid, placement, hp, hero_id, display_name, is_bot}]
## on_result(update: Dictionary): opzionale, chiamata per ogni riga della
## risposta della RPC (vedi sopra). Non chiamata affatto se la RPC fallisce o
## se il match non è ranked (la RPC torna [] in quel caso).
static func write_match(owner: Node, match_id: String, seed_value: int, ranked: bool,
		standings: Array, on_result: Callable = Callable()) -> void:
	var url := OS.get_environment("DB_API_URL").rstrip("/")
	if url == "":
		print("StatsWriter: DB_API_URL assente — no-op. ",
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
	var headers := PackedStringArray(["Content-Type: application/json"])

	var http := HTTPRequest.new()
	owner.add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		if code >= 200 and code < 300:
			print("StatsWriter: match %s registrato (RPC)" % match_id)
			if on_result.is_valid():
				_dispatch_updates(body, on_result)
		else:
			push_warning("StatsWriter: RPC fallita (result=%d code=%d) — fallback match_history. %s" % [
				result, code, body.get_string_from_utf8()])
			_fallback_insert(owner, url, match_id, seed_value, ranked, standings)
		http.queue_free())
	var err := http.request(url + RPC_PATH, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		push_warning("StatsWriter: HTTPRequest.request err %d" % err)
		http.queue_free()


static func _dispatch_updates(body: PackedByteArray, on_result: Callable) -> void:
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY:
		return  # match non ranked (la RPC torna []) o corpo inatteso: niente da fare
	for entry in parsed:
		if typeof(entry) == TYPE_DICTIONARY:
			on_result.call(entry)


static func _fallback_insert(owner: Node, url: String, match_id: String,
		seed_value: int, ranked: bool, standings: Array) -> void:
	var row := {
		"match_id": match_id,
		"seed": seed_value,
		"ranked": ranked,
		"ended_at": Time.get_datetime_string_from_system(true),
		"results": _human_results(standings),
	}
	var headers := PackedStringArray([
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
## hanno un profilo sul server.
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
