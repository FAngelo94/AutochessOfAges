# SETUP_DB.md — database e autenticazione self-hosted

Sostituisce `SETUP_SUPABASE.md`. Al termine il backend è **Postgres + PostgREST +
master + worker + Caddy su una sola macchina**; l'unico servizio esterno è Google
(login). Design completo in `SELFHOST_PLAN.md`.

Si segue dall'alto in basso, una volta sola. Segnaposto:

| Segnaposto | Esempio |
|---|---|
| `game.tuodominio.it` | dominio del VPS |
| `<vps-ip>` | IP pubblico del VPS |
| `<auth-pw>` | password del ruolo Postgres `autochess_auth` (la scegli tu) |
| `<google-client-id>` / `<google-client-secret>` | dalla Google Cloud Console |

---

## 1. Sviluppo locale (Windows/Mac/Linux, richiede Docker)

```sh
docker compose -f db/docker-compose.dev.yml up -d
DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/autochess db/apply.sh
psql "postgresql://postgres:postgres@127.0.0.1:5432/autochess" -f db/seed.sql
```

PostgREST è su `http://127.0.0.1:3000`. Verifica:

```sh
curl -s http://127.0.0.1:3000/profiles?select=username    # -> [{"username":"Sviluppatore"}]
```

Per i test headless di Godot **non serve niente di tutto questo**: senza
`DB_API_URL` nell'ambiente `DbClient` e `StatsWriter` sono no-op e
`tests/net_smoke.gd` gira lo stesso.

Stop: `docker compose -f db/docker-compose.dev.yml down` (`-v` azzera il volume).

---

## 2. Google Cloud Console — OAuth Client ID

Serve un client di tipo **Desktop app** (il redirect è `http://127.0.0.1:<porta>/callback`,
che i client "Web application" non accettano con porta arbitraria).

1. <https://console.cloud.google.com/> → progetto `autochess-of-ages`.
2. **APIs & Services → OAuth consent screen**: User type **External**; nome app,
   email; scope di default (`openid`, `.../userinfo.email`, `.../userinfo.profile`);
   aggiungi il tuo indirizzo tra i **Test users** finché l'app è in "Testing".
   Per il lancio pubblico: **Publish app** (nessuna verifica Google richiesta con
   questi soli scope non sensibili).
3. **Credentials → Create Credentials → OAuth client ID → Desktop app**, nome
   `autochess-desktop`. **Create**.
4. Copia **Client ID** (`<google-client-id>`) e **Client secret** (`<google-client-secret>`).

Non serve registrare redirect URI: per i client Desktop Google accetta i loopback
`http://127.0.0.1:*` in automatico.

---

## 3. Postgres sul VPS

Da `deploy@<vps-ip>` (utente creato in `SETUP_VPS.md` §2):

```sh
sudo apt install -y postgresql-16 postgresql-client-16
sudo -u postgres createdb autochess
```

Verifica che Postgres ascolti solo sul loopback (default Debian/Ubuntu — **confermalo**):

```sh
grep "^listen_addresses" /etc/postgresql/16/main/postgresql.conf   # 'localhost' o commentato
```

### Ruolo di connessione di PostgREST

`db/migrations/0001_initial.sql` crea i ruoli `autochess_app` (nologin) e
`autochess_auth` (login) con password `CHANGE_ME`. Dopo aver applicato le
migrazioni (passo 4), imposta la password vera:

```sh
sudo -u postgres psql -d autochess -c "alter role autochess_auth password '<auth-pw>';"
```

---

## 4. Applicare lo schema

```sh
sudo -u autochess git -C /opt/autochess/app pull    # se non già fatto
DB_URL=postgresql://postgres@127.0.0.1:5432/autochess /opt/autochess/app/db/apply.sh
```

Deve stampare `apply 0001_initial.sql` e `migrazioni allineate`. Poi la password
del ruolo (passo 3). Controllo:

```sh
sudo -u postgres psql -d autochess -c "\dt public.*"
# profiles, player_stats, owned_civs, match_history, sessions, schema_migrations
```

---

## 5. PostgREST

```sh
cd /tmp
curl -LO https://github.com/PostgREST/postgrest/releases/download/v12.2.3/postgrest-v12.2.3-linux-static-x64.tar.xz
tar -xJf postgrest-v12.2.3-linux-static-x64.tar.xz
sudo install -o root -g root -m 755 postgrest /usr/local/bin/postgrest
postgrest --version

sudo install -m 600 -o root -g root /opt/autochess/app/deploy/postgrest.conf /etc/autochess/postgrest.conf
sudo nano /etc/autochess/postgrest.conf     # metti <auth-pw> in db-uri

sudo cp /opt/autochess/app/deploy/autochess-postgrest.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now autochess-postgrest
sudo systemctl status autochess-postgrest    # active (running)
```

Verifica (dal VPS):

```sh
curl -s 'http://127.0.0.1:3000/profiles?select=id'          # -> [] (o righe)
```

Da **fuori** la stessa richiesta deve andare in timeout: `curl` da un'altra
macchina verso `http://<vps-ip>:3000/` → nessuna risposta (porta non aperta).

---

## 6. Secret del server

```sh
sudo install -m 600 -o root -g root /opt/autochess/app/deploy/env.example /etc/autochess/env
sudo nano /etc/autochess/env
```

Compila:

| Variabile | Valore |
|---|---|
| `DB_API_URL` | `http://127.0.0.1:3000` |
| `GOOGLE_CLIENT_ID` | `<google-client-id>` |
| `GOOGLE_CLIENT_SECRET` | `<google-client-secret>` |
| `SESSION_TOKEN_SECRET` | `openssl rand -hex 32` |
| `MATCH_TOKEN_SECRET` | `openssl rand -hex 32` (stesso valore per master e worker: è già lo stesso file) |
| `BACKUP_DB_URL` | `postgresql://postgres@127.0.0.1:5432/autochess` |
| `BACKUP_SSH_TARGET` / `BACKUP_SSH_PORT` | Storage Box (vedi `SETUP_VPS.md` §10) |

Poi (ri)avvia master e worker: `sudo systemctl restart autochess-master autochess-worker@1`.

---

## 7. Cron: pulizia delle sessioni scadute

```sh
sudo -u autochess crontab -e
```

```
23 4 * * *  psql -d autochess -c 'select public.purge_expired_sessions();' >/dev/null
```

(Il `pg_dump` notturno di `SETUP_VPS.md` §10 è un'altra riga di questo stesso crontab.)

---

## 8. Client

In `data/backend.json` (nel repo, tracciato coi segnaposto):

```json
{
  "game_host": "game.tuodominio.it",
  "google_client_id": "<google-client-id>"
}
```

Nessuna chiave segreta: il `google_client_id` è pubblico e lo scambio del code lo
fa il master. Con i segnaposto il gioco resta offline/ospite (invariante:
"il single-player funziona senza account").

---

## 9. Verifica end-to-end

```sh
# handshake WebSocket dall'esterno
npx wscat -c wss://game.tuodominio.it/ws/mm      # deve connettersi senza errori TLS
```

Prova finale: login Google da dispositivo reale → il gioco riceve `AUTH_OK` → la
sessione sopravvive al riavvio dell'app (refresh token) → due dispositivi in coda
→ partita a 8 → `select * from player_stats` aggiornata a fine partita.

---

## Cosa si è perso rispetto a Supabase (accettarlo)

- **Niente PITR**: il ripristino massimo è all'ultimo `pg_dump` notturno.
- **Sei tu il DBA**: patch di Postgres (via `unattended-upgrades`) e di PostgREST
  (binario a mano — metti in calendario il controllo delle release).
- **Single point of failure**: DB, auth e gioco sulla stessa macchina.
- **Nessun cruscotto**: si usa `psql`. Se serve una UI, `pgweb` dietro
  `basic_auth` di Caddy su una route dedicata.
