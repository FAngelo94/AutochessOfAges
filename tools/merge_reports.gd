extends SceneTree

## Fonde N report prodotti da più istanze parallele di tools/balance_sim.gd
## (stessa forma di UnitTelemetry.report_dict) in un unico report, come se
## fossero state un'unica run seriale con tutte le partite.
##
##   godot --headless --path . --script res://tools/merge_reports.gd -- \
##       --files=user://shard_0.json;user://shard_1.json \
##       --out=user://merged.json --label="con abilità"
##
## Usa BalanceReport.merge/finish_merge, le stesse funzioni con cui
## tools/unit_balance.gd ricompone le righe di telemetry.jsonl: un solo modo
## di sommare report, qualunque sia la fonte.

var files: Array[String] = []
var out_path := "user://merged_report.json"
var label := ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--files="):
			for p in arg.split("=", false, 1)[1].split(";"):
				if p != "":
					files.append(p)
		elif arg.begins_with("--out="):
			out_path = arg.split("=")[1]
		elif arg.begins_with("--label="):
			label = arg.split("=", false, 1)[1]

	if files.is_empty():
		printerr("Nessun --files= indicato.")
		quit(1)
		return

	var merged := {}
	for path in files:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			printerr("Impossibile aprire %s" % path)
			quit(1)
			return
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) != TYPE_DICTIONARY:
			printerr("%s non contiene un report valido" % path)
			quit(1)
			return
		merged = BalanceReport.merge(merged, parsed)

	merged = BalanceReport.finish_merge(merged)

	var subtitle := "REPORT BILANCIAMENTO — %d partite fuse da %d shard%s" % [
		int(merged.get("matches", 0)), files.size(),
		(" (%s)" % label) if label != "" else ""]
	BalanceReport.print_full(merged, subtitle)

	var out := FileAccess.open(out_path, FileAccess.WRITE)
	out.store_string(JSON.stringify(merged, "  "))
	out.close()
	print("\nJSON: %s -> %s" % [out_path, ProjectSettings.globalize_path(out_path)])

	quit(0)
