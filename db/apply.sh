#!/usr/bin/env bash
#
# apply.sh — applica in ordine le migrazioni di db/migrations/ a un database
# Postgres, tenendo traccia di quelle gia' applicate. Rimpiazza `supabase db push`.
#
# Uso:
#   DB_URL=postgresql://postgres@127.0.0.1:5432/autochess  db/apply.sh
#   (oppure passare l'URL come primo argomento)
#
# Idempotente: rilanciarlo applica solo le migrazioni nuove. Richiede `psql`.

set -euo pipefail

DB_URL="${1:-${DB_URL:-}}"
[ -n "$DB_URL" ] || { echo "manca DB_URL (env o primo argomento)"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
MIGRATIONS="$HERE/migrations"

psql "$DB_URL" -v ON_ERROR_STOP=1 -q -c "
  create table if not exists public.schema_migrations (
    filename   text primary key,
    applied_at timestamptz not null default now()
  );"

shopt -s nullglob
for f in "$MIGRATIONS"/*.sql; do
  name="$(basename "$f")"
  already="$(psql "$DB_URL" -tAc \
    "select 1 from public.schema_migrations where filename = '$name'")"
  if [ "$already" = "1" ]; then
    echo "  skip  $name"
    continue
  fi
  echo "  apply $name"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q --single-transaction \
    -f "$f" \
    -c "insert into public.schema_migrations (filename) values ('$name');"
done

# PostgREST tiene in cache lo schema al proprio avvio: una funzione creata da
# una migrazione appena applicata resta invisibile — /rpc/<nome> risponde 404 —
# finche' non gli si dice di rileggerlo. Senza questa riga bisogna ricordarsi
# di riavviare postgrest a mano dopo ogni migrazione che tocca le RPC, e la
# dimenticanza si manifesta lato client come un generico "servizio non
# disponibile". NOTIFY e' innocuo se PostgREST non e' in ascolto.
psql "$DB_URL" -q -c "notify pgrst, 'reload schema';"
echo "  cache dello schema di PostgREST ricaricata"

echo "migrazioni allineate."
