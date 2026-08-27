# deploy/

File di deploy per il server autoritativo su VPS (Hetzner + Caddy + systemd).
Sono **bozze funzionanti**: la rifinitura finale è M7 del `MULTIPLAYER_PLAN.md`.

| File | Destinazione sul VPS | Scopo |
|---|---|---|
| `Caddyfile` | `/etc/caddy/Caddyfile` | reverse proxy TLS, route statiche `/ws/mm` e `/ws/w1` |
| `autochess-master.service` | `/etc/systemd/system/` | master server (matchmaking) su `127.0.0.1:9000` |
| `autochess-worker@.service` | `/etc/systemd/system/` | unit template worker: `@1` → `127.0.0.1:9001` |
| `env.example` | `/etc/autochess/env` (mode 0600) | secret: Supabase + `MATCH_TOKEN_SECRET` |
| `backup-db.sh` | `/opt/autochess/backup-db.sh` (cron notturno) | `pg_dump` → Hetzner Storage Box |

La procedura passo-passo completa (creazione VPS, hardening, DNS, Godot headless,
deploy, Caddy, systemd, verifica, backup + prova di restore, runbook, costi) è in
[`../SETUP_VPS.md`](../SETUP_VPS.md).
