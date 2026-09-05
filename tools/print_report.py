import json, sys

## Stampa lo stesso report leggibile che balance_sim.gd stampa a fine run,
## a partire da un JSON già pronto (tipico caso: l'output di merge_shards.py,
## che non passa per _report() dentro Godot). Uso: print_report.py report.json

def pct(a, b):
    return 0.0 if b == 0 else 100.0 * a / b


def main(path):
    d = json.load(open(path, encoding="utf-8"))
    matches = d["matches"]
    total_rounds = d["total_rounds"]

    print("=" * 78)
    print("REPORT BILANCIAMENTO — %d partite, seed base %s (merge di più shard)" % (matches, d.get("base_seed")))
    print("round totali giocati: %d (%.1f/partita) | pareggi di round: %.1f%% | durata media round: %.1fs" % (
        total_rounds, total_rounds / max(matches, 1), d["round_draw_pct"], d["avg_round_duration"]))
    if d.get("level_n"):
        print("livello finale: medio %.1f, massimo osservato %d" % (
            d["level_sum"] / d["level_n"], d["max_level_seen"]))

    rows = list(d["units"].values())
    rows.sort(key=lambda u: -pct(u["wins"], u["wins"] + u["losses"]))

    print("\n%-16s %-7s %2s  %6s %7s  %7s %7s %7s  %6s  %5s  %5s  %5s" % (
        "unità", "civ", "$", "winrt", "round", "dmg/r", "abil/r", "sub/r", "cure/r", "cast", "mort", "plc"))
    print("-" * 100)
    for u in rows:
        wl = u["wins"] + u["losses"]
        rr = max(u["rounds"], 1)
        dmg = (u["dmg_phys"] + u["dmg_magic"] + u["dmg_true"]) / rr
        plc = (u["placement_sum"] / u["placement_n"]) if u["placement_n"] else 0.0
        print("%-16s %-7s %2d  %5.1f%% %7d  %7.0f %7.0f %7.0f  %6.0f  %5.2f  %4.2f  %4.1f" % (
            u["name"][:16], u["origin"][:7], u["cost"],
            pct(u["wins"], wl), u["rounds"],
            dmg, u["dmg_magic"] / rr, u["dmg_taken"] / rr, u["healing"] / rr,
            u["casts"] / rr, u["deaths"] / rr, plc))

    print("\nSINERGIE (winrate del round quando la soglia è attiva)")
    print("%-22s %9s %8s %7s" % ("tratto@soglia", "round", "winrt", "pareg"))
    print("-" * 60)
    trows = list(d["traits"].values())
    trows.sort(key=lambda t: (t["trait"], t["threshold"]))
    for t in trows:
        dec = t["games"] - t["draws"]
        print("%-22s %9d %7.1f%% %6.1f%%" % (
            "%s@%d" % (t["trait"], t["threshold"]), t["games"], pct(t["wins"], dec), pct(t["draws"], t["games"])))

    print("\nSEGNALAZIONI")
    any_flag = False
    for u in rows:
        wl = u["wins"] + u["losses"]
        if wl < 30:
            continue
        wr = pct(u["wins"], wl)
        plc = (u["placement_sum"] / u["placement_n"]) if u["placement_n"] else 0.0
        if wr >= 58.0:
            print("  [FORTE ] %-16s winrate round %.1f%% (n=%d), plc medio %.2f" % (u["name"], wr, wl, plc))
            any_flag = True
        elif wr <= 42.0:
            print("  [DEBOLE] %-16s winrate round %.1f%% (n=%d), plc medio %.2f" % (u["name"], wr, wl, plc))
            any_flag = True
    for u in rows:
        if u["rounds"] < 20:
            print("  [POCO USATA] %-16s solo %d round schierati" % (u["name"], u["rounds"]))
            any_flag = True
    for t in trows:
        dec = t["games"] - t["draws"]
        if dec < 30:
            continue
        wr = pct(t["wins"], dec)
        if wr >= 60.0:
            print("  [SINERGIA FORTE ] %s@%d winrate %.1f%% (n=%d)" % (t["trait"], t["threshold"], wr, dec))
            any_flag = True
        elif wr <= 40.0:
            print("  [SINERGIA DEBOLE] %s@%d winrate %.1f%% (n=%d)" % (t["trait"], t["threshold"], wr, dec))
            any_flag = True
    if not any_flag:
        print("  nessuna: tutto entro banda 42–58% e copertura sufficiente")


if __name__ == "__main__":
    main(sys.argv[1])
