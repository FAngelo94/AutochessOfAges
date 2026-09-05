# db/

Schema Postgres del backend self-hosted (SELFHOST_PLAN.md). Il database gira sul
VPS insieme a master, worker e Caddy; il server di gioco lo raggiunge via
**PostgREST** sul loopback (`127.0.0.1:3000`), mai direttamente.

La **sorgente di verità** è `migrations/`. Non modificare lo schema a mano in
produzione senza riportare la modifica in una nuova migrazione.

| File | Ruolo |
|---|---|
| `migrations/0001_initial.sql` | tabelle, funzioni account/sessioni, RPC `record_match_result`, ruoli e grant |
| `migrations/0002_rank_mmr.sql` | `record_match_result` calcola anche l'mmr a piazzamento e ritorna i delta per client |
| `migrations/0003_email_password.sql` | account con email e password accanto a Google (bcrypt via `pgcrypto`) |
| `migrations/0004_match_units.sql` | `match_units` + telemetria in `record_match_result`, RPC `player_match_history`, vista `unit_balance` |
| `apply.sh` | applica le migrazioni non ancora presenti, traccia in `public.schema_migrations` |
| `unit_balance.sql` | le query di bilanciamento da lanciare a mano (`psql "$DB_URL" -f db/unit_balance.sql`) |
| `docker-compose.dev.yml` | Postgres + PostgREST in locale, al posto di `supabase start` |
| `seed.sql` | dati di comodo per lo sviluppo locale |

## Tabelle

| Tabella | Chi legge | Chi scrive |
|---|---|---|
| `profiles` | il server (master) | `favourite_*` via PROFILE_SET; `upsert_google_account` per il resto |
| `player_stats` | il server (bundle di login) | **solo** `record_match_result` (SECURITY DEFINER) |
| `owned_civs` | il server (rivalidazione hero, bundle) | `upsert_google_account` per le default |
| `match_history` | il server (RPC `player_match_history`) | `record_match_result` |
| `match_units` | chi bilancia (vista `unit_balance`) | `record_match_result` |
| `sessions` | — | `store_refresh_token` / `redeem_refresh_token` |

Come `match_history`, `match_units` non ha FK verso `profiles` e `delete_account`
non la ripulisce: sono partite gia' giocate, e i loro numeri restano validi per
il bilanciamento anche quando l'account sparisce.

Nessuna Row Level Security: PostgREST è raggiungibile solo dai processi sulla
stessa macchina e il ruolo `autochess_app` è a privilegio minimo. Se il client
tornasse mai a parlare HTTP col DB, la RLS va rimessa **prima** (vedi il commento
in testa a `0001_initial.sql`).

## Comandi

```sh
# locale (richiede Docker)
docker compose -f db/docker-compose.dev.yml up -d
DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/autochess db/apply.sh
psql "postgresql://postgres:postgres@127.0.0.1:5432/autochess" -f db/seed.sql
docker compose -f db/docker-compose.dev.yml down          # -v per azzerare il volume

# produzione (sul VPS) — socket Unix + auth peer, nessuna password
sudo -u postgres env DB_URL=postgresql:///autochess /opt/autochess/app/db/apply.sh

# nuova migrazione: crea db/migrations/0002_<nome>.sql e rilancia apply.sh
```

Procedura completa (installazione Postgres + PostgREST, ruoli, OAuth Google,
verifica): [`../SETUP_DB.md`](../SETUP_DB.md).
