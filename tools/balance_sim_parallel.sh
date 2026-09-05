#!/usr/bin/env bash
## Lancia tools/balance_sim.gd su più processi Godot in parallelo (uno per
## core logico assegnato), poi unisce i risultati con merge_shards.py e li
## stampa con print_report.py — stesso identico report di una run singola,
## ma in una frazione del tempo, perché le partite sono indipendenti tra
## loro e ogni processo Godot è single-thread.
##
## Uso:
##   tools/balance_sim_parallel.sh --matches=150 --seed=1 [--shards=6] [--keep]
##
## --keep tiene i JSON dei singoli shard (altrimenti vengono cancellati a
## fine run). Il JSON unito finisce in tools/.balance_run/merged.json.
##
## Richiede GODOT_BIN impostata, o modifica la riga sotto una volta sola.

set -euo pipefail

GODOT_BIN="${GODOT_BIN:-C:/Users/afalc/Downloads/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

matches=150
seed=1
shards=6
keep=0

for arg in "$@"; do
  case "$arg" in
    --matches=*) matches="${arg#*=}" ;;
    --seed=*) seed="${arg#*=}" ;;
    --shards=*) shards="${arg#*=}" ;;
    --keep) keep=1 ;;
    *) echo "argomento sconosciuto: $arg" >&2; exit 1 ;;
  esac
done

work_dir="$ROOT/tools/.balance_run"
mkdir -p "$work_dir"
rm -f "$work_dir"/shard_*.json "$work_dir"/shard_*.log

per_shard=$(( (matches + shards - 1) / shards ))
echo "-> $matches partite in $shards processi da ~$per_shard partite ciascuno"

t0=$(date +%s)
pids=()
for i in $(seq 0 $((shards - 1))); do
  shard_matches=$per_shard
  # L'ultimo shard assorbe il resto della divisione, cosi' il totale torna esatto.
  if [ "$i" -eq $((shards - 1)) ]; then
    already=$(( per_shard * (shards - 1) ))
    shard_matches=$(( matches - already ))
  fi
  if [ "$shard_matches" -le 0 ]; then
    continue
  fi
  shard_seed=$(( seed + i ))
  "$GODOT_BIN" --headless --path "$ROOT" --script res://tools/balance_sim.gd -- \
    --matches="$shard_matches" --seed="$shard_seed" --out="$work_dir/shard_$i.json" \
    > "$work_dir/shard_$i.log" 2>&1 &
  pids+=($!)
done

fail=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done
t1=$(date +%s)

if [ "$fail" -ne 0 ]; then
  echo "ATTENZIONE: almeno uno shard è fallito, controlla $work_dir/shard_*.log" >&2
fi

PYTHONIOENCODING=utf-8 python "$ROOT/tools/merge_shards.py" "$work_dir/merged.json" "$work_dir"/shard_*.json
echo "-> completato in ${t1}-${t0} = $((t1 - t0))s"
echo

PYTHONIOENCODING=utf-8 python "$ROOT/tools/print_report.py" "$work_dir/merged.json"

if [ "$keep" -eq 0 ]; then
  rm -f "$work_dir"/shard_*.json "$work_dir"/shard_*.log
fi
