class_name MatchLog
extends RefCounted

## Cronologia e telemetria delle partite giocate su questo dispositivo.
##
## Sta in app/ per la stessa ragione di app/profile.gd: scrive in user://, cioè
## fuori dal progetto, e la simulazione non deve saperne nulla. Due file, con
## due scopi diversi:
##
##   user://history.json   — le ultime MAX_ENTRIES partite locali, quello che
##                           la schermata Cronologia mostra quando si è offline
##                           o ospiti. Piccolo e sempre riletto per intero.
##   user://telemetry.jsonl — una riga JSON per partita con l'aggregato per
##                           unità (UnitTelemetry.report_dict). Append-only, la
##                           legge solo tools/unit_balance.gd per bilanciare.
##
## Il file di telemetria NON viene mandato al server: le partite contro il
## computer non devono inquinare i numeri del PvP, e dati di bilanciamento
## spediti dal client sarebbero comunque falsificabili.

const HISTORY_PATH := "user://history.json"
const TELEMETRY_PATH := "user://telemetry.jsonl"

## Oltre questa soglia la cronologia perde le partite più vecchie: è una lista
## da scorrere, non un archivio.
const MAX_ENTRIES := 50
## Il file di telemetria cresce di ~10 KB per partita. Superata la soglia viene
## ruotato (.1), così una sessione di bilanciamento lunga non riempie il disco
## e l'analisi precedente resta comunque a portata di mano.
const MAX_TELEMETRY_BYTES := 5 * 1024 * 1024


## Aggiunge una partita alla cronologia locale. `entry` viene completata con la
## data se non ce l'ha già.
static func append_match(entry: Dictionary) -> void:
	var row := entry.duplicate()
	if not row.has("ended_at"):
		row["ended_at"] = Time.get_datetime_string_from_system(true)
	var rows := local_matches()
	rows.push_front(row)
	while rows.size() > MAX_ENTRIES:
		rows.pop_back()
	var file := FileAccess.open(HISTORY_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("MatchLog: impossibile scrivere %s" % HISTORY_PATH)
		return
	file.store_string(JSON.stringify(rows))
	file.close()


## Le partite locali, dalla più recente. Lista vuota se il file non c'è ancora
## o è illeggibile: la cronologia è un di più, non deve mai rompere una schermata.
static func local_matches() -> Array:
	if not FileAccess.file_exists(HISTORY_PATH):
		return []
	var file := FileAccess.open(HISTORY_PATH, FileAccess.READ)
	if file == null:
		return []
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_ARRAY:
		return []
	var out: Array = []
	for row in parsed:
		if typeof(row) == TYPE_DICTIONARY:
			out.append(row)
	return out


## Accoda una riga di telemetria (UnitTelemetry.report_dict di UNA partita).
static func append_telemetry(report: Dictionary) -> void:
	_rotate_telemetry_if_needed()
	var file := FileAccess.open(TELEMETRY_PATH, FileAccess.READ_WRITE) \
		if FileAccess.file_exists(TELEMETRY_PATH) \
		else FileAccess.open(TELEMETRY_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("MatchLog: impossibile scrivere %s" % TELEMETRY_PATH)
		return
	file.seek_end()
	file.store_line(JSON.stringify(report))
	file.close()


## Le righe di telemetria già decodificate, in ordine di scrittura.
static func telemetry_reports() -> Array:
	if not FileAccess.file_exists(TELEMETRY_PATH):
		return []
	var file := FileAccess.open(TELEMETRY_PATH, FileAccess.READ)
	if file == null:
		return []
	var out: Array = []
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line == "":
			continue
		var parsed = JSON.parse_string(line)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.append(parsed)
	file.close()
	return out


static func clear_telemetry() -> void:
	if FileAccess.file_exists(TELEMETRY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TELEMETRY_PATH))


static func _rotate_telemetry_if_needed() -> void:
	if not FileAccess.file_exists(TELEMETRY_PATH):
		return
	var file := FileAccess.open(TELEMETRY_PATH, FileAccess.READ)
	if file == null:
		return
	var size := file.get_length()
	file.close()
	if size < MAX_TELEMETRY_BYTES:
		return
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	dir.remove("telemetry.jsonl.1")
	dir.rename("telemetry.jsonl", "telemetry.jsonl.1")
