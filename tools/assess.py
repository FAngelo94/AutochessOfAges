import json, sys
from collections import defaultdict

## Legge un merged.json di balance_sim e valuta i 3 obiettivi del tuning:
## winrate omogenei, uso omogeneo dentro ogni fascia di costo, durata di
## partita in minuti reali (preparazione + combattimento).
## Uso: assess.py merged.json [preparation_seconds]

def pct(a, b):
    return 0.0 if b == 0 else 100.0 * a / b


def main(path, prep_seconds):
    d = json.load(open(path, encoding="utf-8"))
    total_rounds = d["total_rounds"]
    avg_rounds = total_rounds / d["matches"]
    avg_combat = d["avg_round_duration"]
    minutes = avg_rounds * (prep_seconds + avg_combat) / 60.0

    print("round medi/partita: %.1f | combattimento medio: %.1fs | prep: %.0fs -> durata partita stimata: %.1f min" % (
        avg_rounds, avg_combat, prep_seconds, minutes))
    if d.get("level_n"):
        print("livello finale: medio %.1f, massimo osservato %d" % (d["level_sum"] / d["level_n"], d["max_level_seen"]))

    by_cost = defaultdict(list)
    winrates = []
    for u in d["units"].values():
        wl = u["wins"] + u["losses"]
        wr = pct(u["wins"], wl)
        by_cost[u["cost"]].append((u["name"], u["rounds"], wr, wl))
        if wl >= 30:
            winrates.append(wr)

    print("\n-- uso per fascia di costo (round giocati / round totali di partita) --")
    for cost in sorted(by_cost):
        tier = by_cost[cost]
        vals = [r for _, r, _, _ in tier]
        lo, hi = min(vals), max(vals)
        ratio = (hi / lo) if lo > 0 else float("inf")
        print("costo %d: min=%d max=%d rapporto max/min=%.2fx" % (cost, lo, hi, ratio))
        for name, r, wr, wl in sorted(tier, key=lambda t: -t[1]):
            print("   %-20s round=%6d (%.2f/round)  winrate=%5.1f%% (n=%d)" % (
                name, r, r / total_rounds, wr, wl))

    print("\n-- winrate (unità con n>=30) --")
    if winrates:
        print("min=%.1f%% max=%.1f%% range=%.1f punti | media=%.1f%%" % (
            min(winrates), max(winrates), max(winrates) - min(winrates), sum(winrates) / len(winrates)))


if __name__ == "__main__":
    prep = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
    main(sys.argv[1], prep)
