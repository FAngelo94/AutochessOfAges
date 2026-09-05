class_name BalanceReport
extends RefCounted

## Stampa e fusione dei report di bilanciamento (la forma prodotta da
## UnitTelemetry.report_dict).
##
## Sta in tools/ e non in core/ perché è solo presentazione: nessuno la chiama
## in partita. Esiste per non avere due tabelle diverse a seconda che i numeri
## vengano dalla simulazione di soli bot (tools/balance_sim.gd) o dalle partite
## vere giocate sul dispositivo (tools/unit_balance.gd) — il formato è lo stesso
## anche di tools/print_report.py, che stampa lo stesso JSON da riga di comando.

static func pct(a: float, b: float) -> float:
	return 0.0 if b == 0.0 else 100.0 * a / b


## Stampa il report completo: intestazione, tabella per unità, sinergie e
## segnalazioni. `subtitle` è la riga di contesto (quante partite, che seed).
static func print_full(d: Dictionary, subtitle: String) -> void:
	var units: Dictionary = d.get("units", {})
	var traits: Dictionary = d.get("traits", {})
	var matches := maxi(int(d.get("matches", 0)), 1)
	var total_rounds := int(d.get("total_rounds", 0))
	var level_n := int(d.get("level_n", 0))

	print("\n" + "=".repeat(78))
	print(subtitle)
	print("round totali giocati: %d (%.1f/partita) | pareggi di round: %.1f%% | durata media round: %.1fs" % [
		total_rounds, float(total_rounds) / matches,
		float(d.get("round_draw_pct", 0.0)), float(d.get("avg_round_duration", 0.0))])
	if level_n > 0:
		print("livello finale: medio %.1f, massimo osservato %d" % [
			float(d.get("level_sum", 0)) / level_n, int(d.get("max_level_seen", 0))])

	# ---------- unità ----------
	var rows := units.values()
	rows.sort_custom(func(a, b):
		return pct(a["wins"], a["wins"] + a["losses"]) > pct(b["wins"], b["wins"] + b["losses"]))

	print("\n%-16s %-7s %2s  %6s %7s  %7s %7s %7s  %6s  %5s  %5s  %5s" % [
		"unità", "civ", "$", "winrt", "round", "dmg/r", "abil/r", "sub/r", "cure/r", "cast", "mort", "plc"])
	print("-".repeat(100))
	for u in rows:
		var wl: float = u["wins"] + u["losses"]
		var rr: float = maxf(u["rounds"], 1)
		var dmg: float = (u["dmg_phys"] + u["dmg_magic"] + u["dmg_true"]) / rr
		print("%-16s %-7s %2d  %5.1f%% %7d  %7.0f %7.0f %7.0f  %6.0f  %5.2f  %4.2f  %4.1f" % [
			String(u["name"]).left(16), String(u["origin"]).left(7), int(u["cost"]),
			pct(u["wins"], wl), int(u["rounds"]),
			dmg, u["dmg_magic"] / rr, u["dmg_taken"] / rr, u["healing"] / rr,
			float(u["casts"]) / rr, float(u["deaths"]) / rr,
			(float(u["placement_sum"]) / u["placement_n"]) if int(u["placement_n"]) > 0 else 0.0])

	# ---------- sinergie ----------
	print("\nSINERGIE (winrate del round quando la soglia è attiva)")
	print("%-22s %9s %8s %7s %7s" % ["tratto@soglia", "round", "winrt", "pareg", "n"])
	print("-".repeat(60))
	var trows := traits.values()
	trows.sort_custom(func(a, b):
		return String(a["trait"]) + str(a["threshold"]) < String(b["trait"]) + str(b["threshold"]))
	for t in trows:
		var dec: float = t["games"] - t["draws"]
		print("%-22s %9d %7.1f%% %6.1f%% %7d" % [
			"%s@%d" % [t["trait"], int(t["threshold"])], int(t["games"]),
			pct(t["wins"], dec), pct(t["draws"], t["games"]), int(t["games"])])

	print_flags(rows, trows)


## Segnalazioni automatiche: unità e sinergie fuori da una banda ragionevole.
static func print_flags(rows: Array, trows: Array) -> void:
	print("\nSEGNALAZIONI")
	var any := false
	for u in rows:
		var wl: float = u["wins"] + u["losses"]
		if wl < 30:
			continue
		var wr := pct(u["wins"], wl)
		if wr >= 58.0:
			print("  [FORTE ] %-16s winrate round %.1f%% (n=%d), plc medio %.2f" % [
				u["name"], wr, int(wl), float(u["placement_sum"]) / maxf(u["placement_n"], 1)])
			any = true
		elif wr <= 42.0:
			print("  [DEBOLE] %-16s winrate round %.1f%% (n=%d), plc medio %.2f" % [
				u["name"], wr, int(wl), float(u["placement_sum"]) / maxf(u["placement_n"], 1)])
			any = true
	for u in rows:
		if int(u["rounds"]) < 20:
			print("  [POCO USATA] %-16s solo %d round schierati" % [u["name"], int(u["rounds"])])
			any = true
	for t in trows:
		var dec: float = t["games"] - t["draws"]
		if dec < 30:
			continue
		var wr := pct(t["wins"], dec)
		if wr >= 60.0:
			print("  [SINERGIA FORTE ] %s@%d winrate %.1f%% (n=%d)" % [
				t["trait"], int(t["threshold"]), wr, int(dec)])
			any = true
		elif wr <= 40.0:
			print("  [SINERGIA DEBOLE] %s@%d winrate %.1f%% (n=%d)" % [
				t["trait"], int(t["threshold"]), wr, int(dec)])
			any = true
	if not any:
		print("  nessuna: tutto entro banda 42–58% e copertura sufficiente")


## Somma due report nella stessa forma. Serve a tools/unit_balance.gd, che deve
## ricomporre in un unico quadro le righe di user://telemetry.jsonl (una per
## partita giocata). Le medie (round_draw_pct, avg_round_duration) si ricalcolano
## a fine fusione con finish_merge(), perché una media di medie non è una media.
static func merge(into: Dictionary, other: Dictionary) -> Dictionary:
	if into.is_empty():
		into = {
			"matches": 0, "total_rounds": 0, "level_sum": 0, "level_n": 0,
			"max_level_seen": 0, "units": {}, "traits": {},
			"_draw_sum": 0.0, "_duration_sum": 0.0, "_duration_n": 0.0,
		}
	for key in ["matches", "total_rounds", "level_sum", "level_n"]:
		into[key] = int(into.get(key, 0)) + int(other.get(key, 0))
	into["max_level_seen"] = maxi(int(into["max_level_seen"]), int(other.get("max_level_seen", 0)))

	# Le medie del report sorgente sono percentuali e secondi: per rifonderle
	# servono i totali, che si ricostruiscono dai round di quella partita.
	var rounds := float(other.get("total_rounds", 0))
	into["_draw_sum"] = float(into["_draw_sum"]) + float(other.get("round_draw_pct", 0.0)) / 100.0 * rounds
	into["_duration_sum"] = float(into["_duration_sum"]) + float(other.get("avg_round_duration", 0.0)) * rounds
	into["_duration_n"] = float(into["_duration_n"]) + rounds

	_merge_counters(into["units"], other.get("units", {}), ["id", "name", "origin", "cost"])
	_merge_counters(into["traits"], other.get("traits", {}), ["trait", "threshold"])
	return into


## Chiude la fusione ricalcolando le medie dai totali accumulati.
static func finish_merge(d: Dictionary) -> Dictionary:
	var n: float = maxf(float(d.get("_duration_n", 0.0)), 1.0)
	d["round_draw_pct"] = 100.0 * float(d.get("_draw_sum", 0.0)) / n
	d["avg_round_duration"] = float(d.get("_duration_sum", 0.0)) / n
	d.erase("_draw_sum")
	d.erase("_duration_sum")
	d.erase("_duration_n")
	return d


## Somma i campi numerici riga per riga; `identity` sono le chiavi descrittive
## (nome, civiltà, costo) che si copiano invece di sommarle.
static func _merge_counters(into: Dictionary, from: Variant, identity: Array) -> void:
	if typeof(from) != TYPE_DICTIONARY:
		return
	for key in from:
		var src: Dictionary = from[key]
		if not into.has(key):
			var fresh := {}
			for field in identity:
				fresh[field] = src.get(field, "")
			into[key] = fresh
		var dst: Dictionary = into[key]
		for field in src:
			if field in identity:
				dst[field] = src[field]
			elif typeof(src[field]) in [TYPE_INT, TYPE_FLOAT]:
				dst[field] = float(dst.get(field, 0)) + float(src[field])
