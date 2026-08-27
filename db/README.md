# db/

Schema Postgres di Supabase per il multiplayer (MULTIPLAYER_PLAN.md M1).

La **sorgente di verità** è `migrations/`. Non modificare lo schema dal cruscotto
Supabase senza poi riportare la modifica in una nuova migrazione.

| File | Ruolo |
|---|---|
| `config.toml` | configurazione della CLI Supabase (porte locali, provider Google, redirect loopback) |
| `migrations/0001_initial.sql` | tabelle, trigger di primo login, RPC `record_match_result`, RLS |
| `seed.sql` | dati di comodo per lo sviluppo locale (quasi vuoto — vedi commenti) |

## Tabelle

| Tabella | Chi legge | Chi scrive |
|---|---|---|
| `profiles` | l'utente, solo la propria riga (RLS) | l'utente (favourite_origin/hero) + trigger |
| `player_stats` | l'utente, solo la propria (RLS) | **solo il server** (service_role) via `record_match_result` |
| `owned_civs` | l'utente, solo le proprie (RLS) | **solo il server** (trigger per le default, acquisti in futuro) |
| `match_history` | nessuno dal client (nessuna policy) | **solo il server** |

La anon key è nell'APK: la RLS è l'unica protezione. La service_role key
bypassa la RLS e vive **solo** sul VPS (`/etc/autochess/env`).

## Comandi

```sh
# locale (richiede Docker)
supabase start                 # Postgres + Auth + Studio (localhost:54323)
supabase db reset              # riapplica migrations/ + seed.sql da zero
supabase stop

# produzione
supabase link --project-ref <project-ref>
supabase db push               # applica le migrazioni non ancora presenti
```

Procedura completa (creazione progetto, provider Google, chiavi, verifica RLS):
[`../SETUP_SUPABASE.md`](../SETUP_SUPABASE.md).

## Contratto della RPC `record_match_result`

Invocata da `server/stats_writer.gd` a fine partita con la service_role key:

```
POST /rest/v1/rpc/record_match_result
{
  "p_match_id": "<id assegnato dal master>",
  "p_seed": <bigint>,
  "p_ranked": <bool>,
  "p_results": [
    {"profile_id": "<uuid>", "placement": 1, "hp": 34, "hero_id": "caesar",
     "top4": true, "won": true},
    ...
  ]
}
```

Scrive `match_history` (upsert su `match_id`) e incrementa `matches_played` /
`wins` / `top4` in `player_stats` per ogni `profile_id`, tutto in una transazione
server-side. `grant execute` solo a `service_role`.
