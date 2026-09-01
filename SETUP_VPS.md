# Setup del VPS — server autoritativo Autochess Of Ages

Guida passo-passo per mettere in produzione il backend self-hosted su un VPS
Hetzner: Postgres + PostgREST + master + worker + Caddy su una sola macchina, con
TLS automatico (Caddy), riavvio automatico (systemd) e backup del database.
L'unico servizio esterno è Google (login).

Prerequisito: leggere **`SELFHOST_PLAN.md`** (design) e tenere a portata
**`SETUP_DB.md`** — i passi 3–6 di quella guida (Postgres, schema, ruoli,
PostgREST, OAuth Google, `/etc/autochess/env`) si incastrano qui tra il §6 e il §9.

I file di deploy citati qui sono in **`deploy/`** nel repo. Sono bozze
funzionanti; questa guida spiega come installarli e cosa personalizzare.

## Segnaposto usati in questa guida

| Segnaposto | Significato | Esempio |
|---|---|---|
| `game.tuodominio.it` | sottodominio dedicato al server di gioco | `game.autochess.it` |
| `<vps-ip>` | IP pubblico del VPS | `95.217.xxx.xxx` |
| `<auth-pw>` | password del ruolo Postgres `autochess_auth` | — |
| `u123456` | id della Hetzner Storage Box | — |

---

## 1. Creare il server su Hetzner Cloud

1. [console.hetzner.cloud](https://console.hetzner.cloud) → **New Project** → "autochess".
2. **Add Server**:
   - **Location**: `Falkenstein` o `Nuremberg` (Germania). ~15–25 ms dall'Italia.
   - **Image**: `Ubuntu 24.04`.
   - **Type**: `CPX21` (shared vCPU AMD, 3 vCPU / 4 GB / 80 GB, ~8 €/mese). Basta
     per il lancio: 1 master + 1 worker. Si sale a `CPX41` quando il worker 1
     satura una CPU.
   - **SSH key**: incolla la tua chiave pubblica (`cat ~/.ssh/id_ed25519.pub`).
     Se non ne hai una: `ssh-keygen -t ed25519 -C "autochess-vps"`.
   - **Name**: `autochess-prod`.
3. Crea. Annota `<vps-ip>`.
4. (Consigliato) Console Hetzner → **Firewall** → crea una regola:
   - Inbound: `TCP 22` (SSH), `TCP 443` (HTTPS). Nient'altro.
   - Applicala al server. Questo è un secondo livello oltre a `ufw`.

---

## 2. Primo accesso e hardening di base

```sh
ssh root@<vps-ip>
```

### Utente non-root

```sh
adduser --disabled-password --gecos "" deploy
usermod -aG sudo deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
```

Verifica in un **secondo terminale** (non chiudere quello da root):
`ssh deploy@<vps-ip>` deve funzionare.

### Blindare SSH

`sudo nano /etc/ssh/sshd_config.d/99-hardening.conf`:

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
```

```sh
sudo systemctl restart ssh
```

### Firewall e aggiornamenti automatici

```sh
sudo apt update && sudo apt upgrade -y
sudo apt install -y ufw fail2ban unattended-upgrades

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 443/tcp
sudo ufw enable

sudo systemctl enable --now fail2ban
sudo dpkg-reconfigure -plow unattended-upgrades   # rispondi "Sì"
```

> Le porte `9000` (master) e `9001+` (worker) **non vanno aperte**: i processi
> ascoltano solo su `127.0.0.1`, Caddy fa da unico ingresso pubblico.

---

## 3. DNS

Dal pannello del tuo registrar / provider DNS, crea un record:

```
A    game.tuodominio.it    <vps-ip>    TTL 300
```

Verifica (dopo qualche minuto):

```sh
dig +short game.tuodominio.it     # deve restituire <vps-ip>
```

Caddy non otterrà il certificato finché questo record non risolve.

---

## 4. Utente di servizio e cartelle

Da `deploy@<vps-ip>`:

```sh
sudo adduser --system --group --no-create-home --home /opt/autochess autochess
sudo install -d -o autochess -g autochess /opt/autochess
sudo install -d -o autochess -g autochess /opt/autochess/app
sudo install -d -o autochess -g autochess /opt/godot
sudo install -d -o root     -g root     -m 755 /etc/autochess
```

---

## 5. Godot headless

Il server di gioco **è** Godot in modalità headless: nessun export, si esegue il
progetto da sorgente. Un solo binario per master e worker.

```sh
cd /tmp
VER=4.7-stable
curl -LO "https://github.com/godotengine/godot/releases/download/${VER}/Godot_v${VER}_linux.x86_64.zip"
unzip "Godot_v${VER}_linux.x86_64.zip"
sudo install -o autochess -g autochess -m 755 "Godot_v${VER}_linux.x86_64" /opt/godot/godot
/opt/godot/godot --version    # conferma 4.7.stable
```

> Se in futuro passerai a un export `dedicated_server` (preset Linux/X11 in
> `export_presets.cfg`), sostituirai `ExecStart` nelle unit systemd con il path
> del binario esportato. Per ora eseguire da sorgente è più veloce da iterare.

---

## 6. Deploy del codice

```sh
sudo -u autochess git clone https://github.com/<tuo-utente>/AtuochessOfAges.git /opt/autochess/app
cd /opt/autochess/app
sudo -u autochess git checkout feature/multiplayer
```

Import una tantum della cache risorse/classi (ripetere **ogni volta** che si
aggiunge un `class_name`, cioè a ogni deploy di codice nuovo):

```sh
sudo -u autochess HOME=/opt/autochess /opt/godot/godot --headless --path /opt/autochess/app --import
```

Sanity check dei test sul server:

```sh
sudo -u autochess HOME=/opt/autochess /opt/godot/godot --headless --path /opt/autochess/app --script res://tests/run_tests.gd
sudo -u autochess HOME=/opt/autochess /opt/godot/godot --headless --path /opt/autochess/app --script res://tests/net_smoke.gd
```

---

## 7. Database, PostgREST, OAuth, secret

Qui si esegue **`SETUP_DB.md` §3–§6**:

- §3: `apt install postgresql-16`, `createdb autochess`, listen solo su loopback;
- §4: `db/apply.sh` applica lo schema, poi `alter role autochess_auth password '<auth-pw>'`;
- §5: binario PostgREST, `/etc/autochess/postgrest.conf` (con `<auth-pw>`),
  unit `autochess-postgrest`;
- §2 + §6: client OAuth Google "Desktop app" e compilazione di `/etc/autochess/env`
  (`DB_API_URL`, `GOOGLE_CLIENT_ID/SECRET`, `SESSION_TOKEN_SECRET`,
  `MATCH_TOKEN_SECRET`, `BACKUP_*`).

```sh
sudo install -m 600 -o root -g root /opt/autochess/app/deploy/env.example /etc/autochess/env
sudo nano /etc/autochess/env
```

Torna qui al §8 quando `curl -s http://127.0.0.1:3000/profiles?select=id` sul VPS
risponde `[]`.

---

## 8. Caddy

```sh
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy

sudo install -d -m 755 /var/log/caddy
sudo cp /opt/autochess/app/deploy/Caddyfile /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile     # sostituisci game.tuodominio.it col tuo dominio
sudo systemctl reload caddy
sudo journalctl -u caddy -f        # osserva l'emissione del certificato Let's Encrypt
```

Alla prima richiesta HTTPS valida Caddy ottiene il certificato da solo. Se resta
bloccato: verifica il record A (§3) e che la porta 443 sia aperta (`ufw status`).

WebSocket: Caddy v2 fa da proxy ai WebSocket in modo nativo tramite
`reverse_proxy`. Nessuna direttiva `Upgrade` manuale serve.

---

## 9. systemd — PostgREST, master, worker

```sh
sudo cp /opt/autochess/app/deploy/autochess-postgrest.service /etc/systemd/system/
sudo cp /opt/autochess/app/deploy/autochess-master.service    /etc/systemd/system/
sudo cp /opt/autochess/app/deploy/autochess-worker@.service   /etc/systemd/system/
sudo systemctl daemon-reload

sudo systemctl enable --now autochess-postgrest    # se non già fatto al §7 / SETUP_DB §5
sudo systemctl enable --now autochess-master
sudo systemctl enable --now autochess-worker@1

sudo systemctl status autochess-postgrest autochess-master autochess-worker@1
```

`master` e `worker@1` hanno `Requires=autochess-postgrest.service`: se PostgREST
non parte, non partono nemmeno loro.

Entrambi devono risultare `active (running)`. Log in tempo reale:

```sh
sudo journalctl -u autochess-master -f
sudo journalctl -u autochess-worker@1 -f
```

### Aggiungere un secondo worker più avanti

1. `deploy/Caddyfile`: scommenta la riga `reverse_proxy /ws/w2 127.0.0.1:9002`.
2. `sudo cp` del Caddyfile aggiornato, `sudo systemctl reload caddy`.
3. `sudo systemctl enable --now autochess-worker@2`.

La unit è un template: `@2` ascolta automaticamente su `9002` (`--port=90%i`).

---

## 10. Backup del database + prova di restore

Questo è **l'unico** backup che esiste: niente più backup interni gestiti. La
prova di restore qui sotto è **obbligatoria**, non consigliata.

### Installazione

```sh
sudo install -m 700 -o autochess -g autochess /opt/autochess/app/deploy/backup-db.sh /opt/autochess/backup-db.sh
```

### Storage Box Hetzner (~3 €/mese, opzione BX11)

Dalla console Hetzner → **Storage Box** → crea. Poi abilita SSH e autorizza la
chiave del VPS:

```sh
sudo -u autochess ssh-keygen -t ed25519 -f /opt/autochess/.ssh/id_ed25519 -N ""
# copia /opt/autochess/.ssh/id_ed25519.pub nel pannello Storage Box → SSH keys
sudo -u autochess ssh -p 23 u123456@u123456.your-storagebox.de mkdir -p /home/backups/autochess
```

Metti `BACKUP_SSH_TARGET` e `BACKUP_DB_URL` in `/etc/autochess/env` (§7).

### Cron notturno

```sh
sudo -u autochess crontab -e
```

```
17 3 * * *  /opt/autochess/backup-db.sh >> /var/log/autochess-backup.log 2>&1
23 4 * * *  psql -d autochess -c 'select public.purge_expired_sessions();' >/dev/null
```

Esegui subito una volta a mano e controlla che il file arrivi sulla Storage Box:

```sh
sudo -u autochess /opt/autochess/backup-db.sh
sudo -u autochess ssh -p 23 u123456@u123456.your-storagebox.de ls -la /home/backups/autochess
```

### PROVA DI RESTORE (obbligatoria, una volta ora e ogni ~3 mesi)

Un backup mai ripristinato non è un backup.

1. Un Postgres scratch in locale: `docker run --rm -p 5433:5432 -e POSTGRES_PASSWORD=x -d postgres:16`.
2. Scarica l'ultimo dump dalla Storage Box e ripristinalo:
   ```sh
   scp -P 23 u123456@u123456.your-storagebox.de:/home/backups/autochess/autochess-YYYYMMDD-HHMMSS.sql.gz .
   createdb -h localhost -p 5433 -U postgres autochess_restore
   gunzip -c autochess-*.sql.gz | psql "postgresql://postgres:x@localhost:5433/autochess_restore"
   ```
3. Verifica: `\dt public.*` mostra `profiles`, `player_stats`, `owned_civs`,
   `match_history`, `sessions`; `select count(*) from public.match_history;`
   torna un numero sensato.
4. Butta il container.

---

## 11. Verifica end-to-end

```sh
# handshake WebSocket dall'esterno (da un'altra macchina)
npx wscat -c wss://game.tuodominio.it/ws/mm
# oppure: websocat wss://game.tuodominio.it/ws/mm
```

Deve connettersi senza errori TLS. Il server chiuderà la connessione se non
ricevi un `HELLO` valido — è il comportamento atteso: significa che master e
Caddy parlano.

Prova finale: due dispositivi Android reali, login Google, entrambi in coda,
partita che parte a 30 s con 2 umani + 6 bot, combattimento identico sui due
schermi, `player_stats` aggiornate (`sudo -u postgres psql -d autochess -c
'select * from player_stats'`) a fine partita.

---

## 12. Runbook

### Aggiornare il gioco

```sh
cd /opt/autochess/app
sudo -u autochess git pull
sudo -u autochess HOME=/opt/autochess /opt/godot/godot --headless --path . --import
DB_URL=postgresql://postgres@127.0.0.1:5432/autochess db/apply.sh   # migrazioni nuove, se ci sono
sudo systemctl restart autochess-master autochess-worker@1
```

> Le partite in corso sul worker vengono interrotte da un `restart`. Per un
> deploy pulito: droga il traffico (ferma il master così non arrivano nuove
> partite), aspetta che il worker svuoti, poi riavvia entrambi.

### Log

```sh
sudo journalctl -u autochess-master --since "1 hour ago"
sudo journalctl -u autochess-worker@1 -f
sudo tail -f /var/log/caddy/game.access.log | jq .
```

### Caddy non ottiene il certificato

- `dig +short game.tuodominio.it` deve dare `<vps-ip>`.
- `sudo ufw status` → `443/tcp ALLOW`.
- Firewall Hetzner → 443 inbound aperto.
- `sudo journalctl -u caddy -n 100` per l'errore ACME preciso.
- Rate limit Let's Encrypt: 5 tentativi/ora per dominio. Aspetta.

### Il master o un worker va in crash loop

`Restart=always` + `RestartSec=3` li rialza. Se il loop persiste:
`sudo journalctl -u autochess-worker@1 -n 200` mostra lo stack trace GDScript.
Causa tipica: cache classi stantia → rifai `--import`.

---

## 13. Costi indicativi

| Voce | Costo/mese |
|---|---|
| VPS Hetzner CPX21 (Postgres + PostgREST + master + worker stanno in 4 GB) | ~8 € |
| Hetzner Storage Box BX11 | ~3 € |
| Dominio | ~1 €/mese ammortizzato |
| **Totale** | **~12 €/mese** |

Rispetto al backend gestito: niente più ~23 €/mese, in cambio di ~5–6 giorni di
lavoro una tantum e della manutenzione DBA descritta in `SETUP_DB.md`.
