class_name SupabaseAdmin
extends RefCounted

## Letture server-side su Supabase con la SERVICE_ROLE key (bypassa la RLS).
## Speculare a server/stats_writer.gd (che scrive). Usato dal master per
## rivalidare l'hero dichiarato dal client contro owned_civs — "l'hero va
## validato, non creduto" (MULTIPLAYER_PLAN.md M4).
##
## Config via ambiente: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
## Assenti -> is_configured() == false: il chiamante salta il controllo.

const OWNED_CIVS_PATH := "/rest/v1/owned_civs"


static func is_configured() -> bool:
	return OS.get_environment("SUPABASE_URL") != "" \
		and OS.get_environment("SUPABASE_SERVICE_ROLE_KEY") != ""


## cb.call(ok: bool, civ_ids: PackedStringArray). ok=false = lettura fallita
## (il chiamante non deve declassare in caso di errore di rete).
static func fetch_owned_civs(owner: Node, uid: String, cb: Callable) -> void:
	var url := OS.get_environment("SUPABASE_URL").rstrip("/")
	var key := OS.get_environment("SUPABASE_SERVICE_ROLE_KEY")
	if url == "" or key == "" or owner == null or not is_instance_valid(owner) or uid == "":
		cb.call(false, PackedStringArray())
		return

	var http := HTTPRequest.new()
	owner.add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		var civs := PackedStringArray()
		var ok := code >= 200 and code < 300
		if ok:
			var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
			if parsed is Array:
				for row in parsed:
					if row is Dictionary and row.has("civ_id"):
						civs.append(String(row["civ_id"]))
		else:
			push_warning("SupabaseAdmin: owned_civs code=%d" % code)
		http.queue_free()
		cb.call(ok, civs))

	var headers := PackedStringArray([
		"apikey: " + key,
		"Authorization: Bearer " + key,
	])
	var query := "%s%s?select=civ_id&profile_id=eq.%s" % [url, OWNED_CIVS_PATH, uid]
	if http.request(query, headers, HTTPClient.METHOD_GET) != OK:
		http.queue_free()
		cb.call(false, PackedStringArray())
