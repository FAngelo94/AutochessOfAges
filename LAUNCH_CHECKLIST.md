# LAUNCH_CHECKLIST.md — dal codice attuale alla pubblicazione sul Play Store

Ordine consigliato: prima l'infrastruttura (si testa end-to-end), poi il Play
Store. Guide di dettaglio: [`SETUP_DB.md`](SETUP_DB.md),
[`SETUP_VPS.md`](SETUP_VPS.md), [`SELFHOST_PLAN.md`](SELFHOST_PLAN.md) (design).

I link "— guida §N" qui sotto puntano alla sezione esatta della guida
corrispondente.

Il codice è completo: la cancellazione account è stata implementata
(`DELETE_ACCOUNT` sul master → RPC `delete_account`, pulsante in
`ui/settings_panel.gd`, pagina web `deploy/www/elimina-account.html`).

---

## 1. Infrastruttura backend

- [X] Creare un **VPS Hetzner** (CPX21, Ubuntu 24.04, Falkenstein/Nuremberg) — [SETUP_VPS §1](SETUP_VPS.md#1-creare-il-server-su-hetzner-cloud)–[§2](SETUP_VPS.md#2-primo-accesso-e-hardening-di-base)
- [X] Registrare un **dominio o sottodominio** e puntare un record `A` al VPS — [SETUP_VPS §3](SETUP_VPS.md#3-dns)
- [X] Hardening base del VPS (utente non-root, SSH, `ufw`, `fail2ban`) — [SETUP_VPS §2](SETUP_VPS.md#2-primo-accesso-e-hardening-di-base)
- [X] Installare **Godot headless** sul VPS — [SETUP_VPS §5](SETUP_VPS.md#5-godot-headless)
- [ ] `git clone` del repo + `--import` + sanity check dei test — [SETUP_VPS §6](SETUP_VPS.md#6-deploy-del-codice)
- [ ] Installare **Postgres 16**, `createdb autochess`, verificare `listen_addresses = localhost` — [SETUP_DB §3](SETUP_DB.md#3-postgres-sul-vps)
- [ ] Applicare lo schema con `db/apply.sh`, poi impostare la password di `autochess_auth` — [SETUP_DB §4](SETUP_DB.md#4-applicare-lo-schema) + [§3 (ruolo)](SETUP_DB.md#ruolo-di-connessione-di-postgrest)
- [ ] Installare il binario **PostgREST**, `/etc/autochess/postgrest.conf`, unit `autochess-postgrest` — [SETUP_DB §5](SETUP_DB.md#5-postgrest)
- [ ] Creare il **client OAuth Google "Desktop app"** su Google Cloud Console — [SETUP_DB §2](SETUP_DB.md#2-google-cloud-console--oauth-client-id)
- [ ] Compilare `/etc/autochess/env` (`DB_API_URL`, `GOOGLE_CLIENT_ID/SECRET`, `SESSION_TOKEN_SECRET`, `MATCH_TOKEN_SECRET`, `BACKUP_*`) — [SETUP_DB §6](SETUP_DB.md#6-secret-del-server)
- [ ] Installare **Caddy** con il `Caddyfile` (TLS automatico) — [SETUP_VPS §8](SETUP_VPS.md#8-caddy)
- [ ] `systemd`: abilitare `autochess-postgrest`, `autochess-master`, `autochess-worker@1` — [SETUP_VPS §9](SETUP_VPS.md#9-systemd--postgrest-master-worker)
- [ ] **Backup**: `backup-db.sh` + Storage Box Hetzner + cron notturno + cron `purge_expired_sessions` — [SETUP_VPS §10](SETUP_VPS.md#10-backup-del-database--prova-di-restore)
- [ ] **Prova di restore** del backup su un Postgres scratch — [SETUP_VPS §10 (PROVA DI RESTORE)](SETUP_VPS.md#prova-di-restore-obbligatoria-una-volta-ora-e-ogni-3-mesi)
- [ ] Verifica end-to-end: `wscat -c wss://<dominio>/ws/mm` si connette senza errori TLS — [SETUP_VPS §11](SETUP_VPS.md#11-verifica-end-to-end)
- [ ] Mettere `game_host` + `google_client_id` reali in `data/backend.json` (build only, non committare i valori) — [SETUP_DB §8](SETUP_DB.md#8-client)

---

## 2. Legale / contenuti (obbligatori per il Play Store)

- [ ] Installare le pagine statiche sul VPS: `sudo install -d /opt/autochess/www`
      poi `sudo cp deploy/www/*.html /opt/autochess/www/`; `sudo systemctl reload caddy` — [SETUP_VPS §8](SETUP_VPS.md#8-caddy)
- [ ] **Privacy policy**: compilare `deploy/www/privacy.html` (sostituire i
      `REPLACE_WITH_*`, far rivedere il testo) — servita su `<dominio>/privacy`,
      va linkata nella schermata impostazioni dell'app
- [ ] **Pagina cancellazione account**: sostituire `REPLACE_WITH_CONTACT_EMAIL` in
      `deploy/www/elimina-account.html` — servita su `<dominio>/elimina-account`
- [ ] Dichiarare **privacy policy URL** e **URL di cancellazione account** nella
      scheda Play Store
- [ ] **OAuth consent screen** portato da "Testing" a **"In produzione"** (nessuna
      verifica Google necessaria con soli scope `openid`/`email`/`profile`) — [SETUP_DB §2](SETUP_DB.md#2-google-cloud-console--oauth-client-id)

---

## 3. Build Android

- [ ] Generare un **keystore di release** (`keytool`) e conservarlo in un posto sicuro
      + backuppato (perderlo = non poter più aggiornare l'app)
- [ ] Configurarlo in `export_presets.cfg` (o nelle impostazioni di export di Godot)
- [ ] **Progetto → Installa modello di build Android**; attivare **Use Gradle Build** — [android/README.md](android/README.md#compilazione)
- [ ] Verificare il **target API level** richiesto da Google (Godot 4.7 di norma è a posto)
- [ ] Export **AAB** (Android App Bundle) firmato
- [ ] Provarlo su un **dispositivo reale**: login Google → `AUTH_OK` → partita online
      a 8 → statistiche aggiornate; e in modalità aereo l'app resta ospite e il
      single-player funziona — [SETUP_DB §9](SETUP_DB.md#9-verifica-end-to-end)

---

## 4. Play Console

- [ ] Aprire un account **Google Play Console** (25 $ una tantum)
- [ ] Creare l'app, caricare l'AAB su una **traccia interna/chiusa** prima della produzione
- [ ] **Data safety form** (dichiarazione dei dati raccolti e del loro uso)
- [ ] **Content rating** (questionario IARC)
- [ ] **Store listing**: icona, screenshot (telefono + eventualmente tablet),
      feature graphic, descrizione breve e lunga, categoria
- [ ] Testare con test user, poi promuovere in **produzione**

---

## 5. Non serve per il primo lancio (rimandabile)

- [ ] Monetizzazione: build dell'`.aar` RevenueCat (richiede Android SDK) + prodotti
      su Play Console + entitlement su RevenueCat — [android/README.md](android/README.md).
      Il gioco è progettato per restare **pienamente giocabile senza store**.
- [ ] Secondo worker (`autochess-worker@2`) — solo quando 1 worker satura una CPU — [SETUP_VPS §9 (secondo worker)](SETUP_VPS.md#aggiungere-un-secondo-worker-più-avanti)
- [ ] Export **Web/HTML5** — [web/README.md](web/README.md)
