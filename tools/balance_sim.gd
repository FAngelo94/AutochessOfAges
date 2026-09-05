extends SceneTree

## Simulazione di bilanciamento: gioca N partite di soli bot, raccoglie
## statistiche per unità e per sinergia, stampa un report e scrive un JSON.
##
##   godot --headless --path . --script res://tools/balance_sim.gd -- --matches=200 --seed=1
##
## Deterministico: stesso --seed + stesso --matches = stesso report.

var matches := 100
var base_seed := 1
## Percorso di output alternativo a user://balance_report.json, per far
## scrivere ogni processo (quando se ne lanciano più in parallelo, uno per
## quota di partite) sul proprio file senza pestarsi i piedi a vicenda.
var out_path := ""

## L'accumulatore vero e proprio sta in core/unit_telemetry.gd: lo stesso che
## raccoglie i numeri delle partite vere (locali e online), così il report di
## questa simulazione e quello delle partite giocate sono confrontabili.
var telemetry: UnitTelemetry


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--matches="):
			matches = int(arg.split("=")[1])
		elif arg.begins_with("--seed="):
			base_seed = int(arg.split("=")[1])
		elif arg.begins_with("--out="):
			out_path = arg.split("=")[1]

	GameData.ensure_loaded()
	telemetry = UnitTelemetry.new()

	var t0 := Time.get_ticks_msec()
	for m in matches:
		_run_match(base_seed + m * 1000)
		if m % 25 == 0:
			print("  ... partita %d/%d" % [m, matches])
	var secs := (Time.get_ticks_msec() - t0) / 1000.0

	_report(secs)
	quit(0)


func _run_match(match_seed: int) -> void:
	var ms := MatchState.new(match_seed, 0)
	var brains: Array = []
	var brain_rng := SimRNG.new(match_seed ^ 0x5eed)
	for p in ms.players:
		brains.append(BotBrain.new(p, brain_rng.fork(p.index)))

	telemetry.begin_match()
	ms.round_resolved.connect(telemetry.on_round_resolved)

	var rounds := 0
	while ms.phase != MatchState.Phase.FINISHED and rounds < 300:
		ms.start_round()
		for b in brains:
			b.play_preparation(ms.stage)
		ms.resolve_round()
		rounds += 1

	telemetry.on_match_finished(ms)


## La tabella la stampa tools/balance_report.gd, la stessa che usa
## tools/unit_balance.gd sulle partite vere: due sorgenti diverse, un solo
## formato da imparare a leggere.
func _report(secs: float) -> void:
	var out := telemetry.report_dict({"matches": matches, "base_seed": base_seed})
	BalanceReport.print_full(out, "REPORT BILANCIAMENTO — %d partite, seed base %d, %.1fs" % [
		matches, base_seed, secs])

	var path := out_path if out_path != "" else "user://balance_report.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	print("\nJSON: %s -> %s" % [path, ProjectSettings.globalize_path(path)])
