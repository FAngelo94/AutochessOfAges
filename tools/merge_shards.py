import json, sys

## Somma i campi additivi di più JSON prodotti da balance_sim.gd (uno per
## processo Godot lanciato in parallelo su una fetta di partite) in un unico
## report, così come se fosse girato in un solo processo con tutte le
## partite insieme. Uso: merge_shards.py out.json shard1.json shard2.json ...

paths = sys.argv[2:]
shards = [json.load(open(p, encoding="utf-8")) for p in paths]

out = {
    "matches": sum(s["matches"] for s in shards),
    "base_seed": shards[0]["base_seed"],
    "total_rounds": sum(s["total_rounds"] for s in shards),
    "level_sum": sum(s.get("level_sum", 0) for s in shards),
    "level_n": sum(s.get("level_n", 0) for s in shards),
    "max_level_seen": max((s.get("max_level_seen", 0) for s in shards), default=0),
    "units": {},
    "traits": {},
}

# round_draw_pct e avg_round_duration sono medie nei singoli report; le
# ricombino come media pesata sui round totali di ciascuno shard.
tot_rounds_for_avg = sum(s["total_rounds"] for s in shards) or 1
out["round_draw_pct"] = sum(s["round_draw_pct"] * s["total_rounds"] for s in shards) / tot_rounds_for_avg
out["avg_round_duration"] = sum(s["avg_round_duration"] * s["total_rounds"] for s in shards) / tot_rounds_for_avg

sum_fields = ["rounds", "wins", "losses", "round_draws", "dmg_phys", "dmg_magic",
              "dmg_true", "dmg_taken", "healing", "casts", "attacks", "crits",
              "deaths", "star_sum", "fielded_end", "placement_sum", "placement_n", "top4"]
copy_fields = ["id", "name", "origin", "cost"]

for s in shards:
    for uid, v in s["units"].items():
        acc = out["units"].setdefault(uid, {f: 0 for f in sum_fields})
        for f in copy_fields:
            acc[f] = v[f]
        for f in sum_fields:
            acc[f] += v[f]
    for key, t in s["traits"].items():
        acc = out["traits"].setdefault(key, {"trait": t["trait"], "threshold": t["threshold"], "games": 0, "wins": 0, "draws": 0})
        acc["games"] += t["games"]
        acc["wins"] += t["wins"]
        acc["draws"] += t["draws"]

json.dump(out, open(sys.argv[1], "w", encoding="utf-8"), indent=1)
print("scritto %s: %d partite, %d round totali (da %d shard)" % (
    sys.argv[1], out["matches"], out["total_rounds"], len(shards)))
