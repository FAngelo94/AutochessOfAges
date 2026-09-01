# PRODUCTION.md — dati del VPS di produzione

Non un segreto (l'IP diventa comunque pubblico appena un dominio ci punta sopra),
ma tenerlo qui evita di doverlo ripescare da Hetzner ogni volta che cambi
macchina di sviluppo. **Nessuna password o chiave va in questo file** — quelle
vivono solo in `/etc/autochess/env` sul server (vedi `SETUP_DB.md` §6).

| Voce | Valore |
|---|---|
| Nome server (Hetzner) | `autochess-prod` |
| IP pubblico (IPv4) | `168.119.172.181` |
| IPv6 | `2a01:4f8:1c1e:96be::/64` |
| Piano | CX23 — 2 vCPU / 4 GB RAM / 40 GB disco, ~6,70 €/mese |
| Location | Germania (Falkenstein/Norimberga) |
| Dominio | non ancora collegato — record `A` da creare, vedi `SETUP_VPS.md` §3 |
| Utente admin | `deploy` (creato in `SETUP_VPS.md` §2) |
| Utente di servizio | `autochess` (creato in `SETUP_VPS.md` §4) |

## Cronologia

- **2026-09-01**: server creato come CPX12 (1 vCPU / 2 GB, ~14 €/mese —
  sovrapprezzo mai chiarito, verificare in Billing se riappare), poi rescalato
  a CX23 lo stesso giorno.

## Stato del deploy

Aggiorna questa lista man mano che avanzi in `SETUP_VPS.md` / `SETUP_DB.md`:

- [x] Server creato
- [ ] Hardening (utente `deploy`, SSH, `ufw`, `fail2ban`)
- [ ] Dominio + record `A`
- [ ] Godot headless installato
- [ ] Postgres + schema applicato
- [ ] PostgREST
- [ ] OAuth Google configurato
- [ ] `/etc/autochess/env` compilato
- [ ] Caddy + TLS
- [ ] systemd (`autochess-postgrest`, `autochess-master`, `autochess-worker@1`)
- [ ] Backup su Storage Box + prova di restore
- [ ] Verifica end-to-end (`wscat`)

Vedi anche [`LAUNCH_CHECKLIST.md`](../LAUNCH_CHECKLIST.md) per i passi
successivi alla pubblicazione sul Play Store.
