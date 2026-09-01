# deploy/

File di deploy per il backend self-hosted su VPS (Hetzner + Caddy + systemd +
Postgres + PostgREST). Tutto gira su una macchina; l'unico servizio esterno è
Google (identity provider del login).

| File | Destinazione sul VPS | Scopo |
|---|---|---|
| `Caddyfile` | `/etc/caddy/Caddyfile` | reverse proxy TLS, route statiche `/ws/mm` e `/ws/w1` |
| `autochess-postgrest.service` | `/etc/systemd/system/` | PostgREST su `127.0.0.1:3000` (accesso dati) |
| `postgrest.conf` | `/etc/autochess/postgrest.conf` (mode 0600) | config PostgREST, password del ruolo di connessione |
| `autochess-master.service` | `/etc/systemd/system/` | master server (login + matchmaking) su `127.0.0.1:9000` |
| `autochess-worker@.service` | `/etc/systemd/system/` | unit template worker: `@1` → `127.0.0.1:9001` |
| `env.example` | `/etc/autochess/env` (mode 0600) | secret: OAuth Google, `SESSION_TOKEN_SECRET`, `MATCH_TOKEN_SECRET`, `DB_API_URL` |
| `backup-db.sh` | `/opt/autochess/backup-db.sh` (cron notturno) | `pg_dump` del Postgres locale → Hetzner Storage Box |

Setup del database (Postgres + PostgREST + ruoli + OAuth Google):
[`../SETUP_DB.md`](../SETUP_DB.md). Procedura VPS completa (creazione, hardening,
DNS, Godot headless, Caddy, systemd, verifica, backup + prova di restore,
runbook, costi): [`../SETUP_VPS.md`](../SETUP_VPS.md).
