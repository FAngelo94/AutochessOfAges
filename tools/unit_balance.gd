extends SceneTree

## Report di bilanciamento dalle partite VERE giocate su questo dispositivo,
## non da una simulazione di soli bot.
##
##   godot --headless --path . --script res://tools/unit_balance.gd
##   godot --headless --path . --script res://tools/unit_balance.gd -- --out=user://locale.json
##
## Sorgente: user://telemetry.jsonl, una riga per partita locale, scritta a fine
## partita da ui/main.gd (app/match_log.gd). Il formato è quello di
## tools/balance_sim.gd, quindi la tabella si legge allo stesso modo e il JSON
## prodotto passa in tools/print_report.py senza conversioni.
##
## Per le partite ONLINE i numeri stanno su Postgres e non qui: si guardano con
## db/unit_balance.sql (la vista public.unit_balance). Le due sorgenti restano
## separate di proposito — una partita contro il computer non deve spostare i
## numeri del PvP.

var out_path := ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_path = arg.split("=")[1]

	GameData.ensure_loaded()

	var reports := MatchLog.telemetry_reports()
	if reports.is_empty():
		print("Nessuna telemetria in %s." % MatchLog.TELEMETRY_PATH)
		print("Gioca qualche partita contro il computer e rilancia: ogni partita aggiunge una riga.")
		quit(0)
		return

	var merged := {}
	for report in reports:
		merged = BalanceReport.merge(merged, report)
	merged = BalanceReport.finish_merge(merged)

	BalanceReport.print_full(merged, "REPORT BILANCIAMENTO — %d partite locali (%s)" % [
		int(merged.get("matches", 0)), MatchLog.TELEMETRY_PATH])

	if out_path != "":
		var file := FileAccess.open(out_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(merged, "  "))
			file.close()
			print("\nJSON: %s -> %s" % [out_path, ProjectSettings.globalize_path(out_path)])

	quit(0)
