#!/usr/bin/env bash
# Lancia tools/balance_sim.gd come N istanze Godot parallele (una per quota di
# partite), stampa avanzamento/tempo trascorso dal vivo, poi fonde i report
# con tools/merge_reports.gd. Pensato per il test A/B con/senza abilità:
#
#   tools/run_parallel_sim.sh --matches=300 --shards=8 --seed=42 --label=con_abilita
#   tools/run_parallel_sim.sh --matches=300 --shards=8 --seed=42 --label=senza_abilita --no-abilities
#
# Va lanciato dalla root del progetto (dove sta project.godot).
set -euo pipefail

GODOT="/c/Users/afalc/Downloads/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe"
PROJECT_DIR="$(pwd)"
USER_DIR="/c/Users/afalc/AppData/Roaming/Godot/app_userdata/Autochess Of Ages"

MATCHES=300
SHARDS=8
SEED=1
LABEL="run"
EXTRA_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --matches=*) MATCHES="${arg#*=}" ;;
    --shards=*) SHARDS="${arg#*=}" ;;
    --seed=*) SEED="${arg#*=}" ;;
    --label=*) LABEL="${arg#*=}" ;;
    --no-abilities) EXTRA_ARGS+=("--no-abilities") ;;
    *) echo "argomento sconosciuto: $arg" >&2; exit 1 ;;
  esac
done

mkdir -p "$USER_DIR"
LOG_DIR="$(mktemp -d)"
echo "Log per-shard in: $LOG_DIR"

BASE=$((MATCHES / SHARDS))
REM=$((MATCHES % SHARDS))

declare -a PIDS
declare -a SHARD_MATCHES
declare -a OUT_NAMES

START_TS=$(date +%s)

for i in $(seq 0 $((SHARDS - 1))); do
  n=$BASE
  if [[ $i -lt $REM ]]; then n=$((n + 1)); fi
  shard_seed=$((SEED + i * 100000))
  out_name="${LABEL}_shard_${i}.json"

  "$GODOT" --headless --path "$PROJECT_DIR" --script res://tools/balance_sim.gd -- \
    --matches="$n" --seed="$shard_seed" --out="user://${out_name}" "${EXTRA_ARGS[@]}" \
    > "$LOG_DIR/shard_${i}.log" 2>&1 &

  PIDS[$i]=$!
  SHARD_MATCHES[$i]=$n
  OUT_NAMES[$i]="$out_name"
done

echo "[$LABEL] ${SHARDS} istanze lanciate, ${MATCHES} partite totali (quote: ${SHARD_MATCHES[*]})"

while true; do
  alive=0
  total_done=0
  for i in $(seq 0 $((SHARDS - 1))); do
    pid=${PIDS[$i]}
    if kill -0 "$pid" 2>/dev/null; then
      alive=$((alive + 1))
    fi
    progress_file="$USER_DIR/${OUT_NAMES[$i]}.progress"
    if [[ -f "$progress_file" ]]; then
      done_n=$(cut -d/ -f1 < "$progress_file" 2>/dev/null || echo 0)
      [[ "$done_n" =~ ^[0-9]+$ ]] || done_n=0
    else
      done_n=0
    fi
    total_done=$((total_done + done_n))
  done

  elapsed=$(( $(date +%s) - START_TS ))
  pct=$((100 * total_done / MATCHES))
  printf "\r[%s] %d/%d partite (%3d%%) - trascorsi %02d:%02d:%02d - processi attivi: %d/%d   " \
    "$LABEL" "$total_done" "$MATCHES" "$pct" \
    $((elapsed / 3600)) $(((elapsed % 3600) / 60)) $((elapsed % 60)) \
    "$alive" "$SHARDS"

  if [[ $alive -eq 0 ]]; then
    echo
    break
  fi
  sleep 5
done

echo "[$LABEL] tutte le istanze terminate, avvio merge..."

FILES_ARG=""
for name in "${OUT_NAMES[@]}"; do
  FILES_ARG+="user://${name};"
done
FILES_ARG="${FILES_ARG%;}"

MERGED_NAME="${LABEL}_merged.json"

"$GODOT" --headless --path "$PROJECT_DIR" --script res://tools/merge_reports.gd -- \
  --files="$FILES_ARG" --out="user://${MERGED_NAME}" --label="$LABEL"

echo "[$LABEL] report unito: $USER_DIR/$MERGED_NAME"
