# Setup Supabase — Autochess Of Ages

> Guida operativa per il backend online (Auth Google + Postgres) descritto in
> `MULTIPLAYER_PLAN.md`, milestone **M1** (progetto, schema, migrazioni, RLS) e **M2**
> (login Google via loopback + PKCE nel client).
>
> Si segue dall'alto in basso, una volta sola, in una sessione. Ogni comando è in un blocco
> copiabile. Sostituisci i segnaposto:
>
> | Segnaposto | Esempio | Dove si trova |
> |---|---|---|
> | `<project-ref>` | `abcdefghijklmnopqrst` | Supabase → Settings → General → Reference ID |
> | `<db-password>` | (la scegli tu alla creazione) | annotala in un password manager |
> | `game.tuodominio.it` | il dominio del VPS | tuo DNS |
> | `<google-client-id>` | `1234...apps.googleusercontent.com` | Google Cloud Console |
> | `<google-client-secret>` | `GOCSPX-...` | Google Cloud Console |
>
> La cartella `db/` (config, migrazioni, seed) è creata in parallelo da un altro agente. Questa
> guida assume che esista `db/migrations/0001_initial.sql` con lo schema di M1. Se non c'è ancora,
> completa comunque i passi 1-4 e 7, e torna ai passi 5-6 quando il file è pronto.

---

## Indice

1. [Creare il progetto Supabase](#1-creare-il-progetto-supabase)
2. [⚠️ Sicurezza delle chiavi](#2--sicurezza-delle-chiavi)
3. [Google Cloud Console — OAuth Client ID](#3-google-cloud-console--oauth-client-id)
4. [Supabase Auth — provider Google e Redirect URLs](#4-supabase-auth--provider-google-e-redirect-urls)
5. [CLI Supabase — link, push, sviluppo locale](#5-cli-supabase--link-push-sviluppo-locale)
6. [Verifica della RLS](#6-verifica-della-rls)
7. [Piano Pro](#7-piano-pro)
8. [GDPR e cancellazione account](#8-gdpr-e-cancellazione-account)
9. [Checklist finale prima del deploy VPS](#9-checklist-finale-prima-del-deploy-vps)

---

## 1. Creare il progetto Supabase

1. Vai su <https://supabase.com/dashboard>, accedi (login con GitHub va bene).
2. **New project**.
   - **Name**: `autochess-of-ages`
   - **Database Password**: generane una forte e **salvala subito** (`<db-password>`). Serve per
     `supabase db push` e per il `pg_dump` di backup. Non è recuperabile in chiaro dopo.
   - **Region**: **Central EU (Frankfurt)** — internamente `eu-central-1`. È vincolante: il piano
     M1 fissa Frankfurt per la latenza dall'Italia e per la co-locazione col VPS Hetzner.
   - **Pricing plan**: Free per ora (l'upgrade a Pro è il passo 7, prima del lancio pubblico).
3. Attendi ~2 minuti il provisioning.

### Dove trovare `project-ref`, URL e chiavi

**Settings → General**
- **Reference ID** = `<project-ref>`. È anche il sottodominio: l'API sta su
  `https://<project-ref>.supabase.co`.

**Settings → API**
- **Project URL**: `https://<project-ref>.supabase.co` — va nel client e nel `/etc/autochess/env`
  del VPS come `SUPABASE_URL`.
- **Project API keys**:
  - **`anon` `public`** — chiave pubblica. Può stare nell'APK. Protetta **solo** dalla RLS.
  - **`service_role` `secret`** — bypassa la RLS, accesso totale al DB. **Solo VPS.** Vedi il
    box qui sotto.
- **JWT Settings → JWT Secret** e l'endpoint JWKS `https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json`
  — servono al master server (M4) per verificare i token. Prendine nota, non serve copiarli ora.

Copia URL, `anon` key e `service_role` key in un file temporaneo sicuro: li usi nei passi
successivi.

---

## 2. ⚠️ Sicurezza delle chiavi

> ```
> ┌─────────────────────────────────────────────────────────────────────────────┐
> │  ⚠️  DUE CHIAVI, DUE REGOLE OPPOSTE. NON CONFONDERLE.                         │
> ├─────────────────────────────────────────────────────────────────────────────┤
> │                                                                             │
> │  anon key (public)                                                           │
> │    • PUÒ stare nell'APK e nel repo (data/backend.json o data/catalog.json).  │
> │    • È inutile senza un JWT valido: la RLS blocca ogni riga.                  │
> │    • Se la RLS NON è attiva su una tabella, questa chiave la legge tutta.     │
> │      → il passo 6 verifica che la RLS sia davvero attiva.                     │
> │                                                                             │
> │  service_role key (secret)                                                   │
> │    • BYPASSA la RLS. Con questa si legge e scrive QUALSIASI riga.             │
> │    • SOLO sul VPS, in /etc/autochess/env, permessi 0600, owner root.         │
> │    • MAI nell'APK. MAI nel repo. MAI in un log. MAI in un messaggio di rete. │
> │    • MAI in data/, in export_presets.cfg, in un file di test.                │
> │    • La usano solo master_server.gd e game_worker.gd sul VPS.                │
> │                                                                             │
> │  Se la service_role key trapela: Settings → API → "Generate new             │
> │  service_role secret" e aggiorna /etc/autochess/env. Ruota subito.          │
> └─────────────────────────────────────────────────────────────────────────────┘
> ```

Sul VPS (dettagli completi in M7, qui solo la parte chiavi):

```sh
sudo mkdir -p /etc/autochess
sudo tee /etc/autochess/env > /dev/null <<'EOF'
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<incolla-qui-la-service_role-key>
MATCH_TOKEN_SECRET=<genera-con: openssl rand -hex 32>
EOF
sudo chmod 0600 /etc/autochess/env
sudo chown root:root /etc/autochess/env
```

Aggiungi al `.gitignore` del repo (se non c'è già) una riga di sicurezza:

```gitignore
# secret backend — non committare mai
**/service_role*
/etc/autochess/
*.dat
```

Nel repo va **solo** la `anon` key, e solo se decidi di tenerla in `data/backend.json`. In
alternativa la si passa alla build come parametro d'export.

---

## 3. Google Cloud Console — OAuth Client ID

Serve un OAuth 2.0 Client ID di tipo **Web application** (non "Android": il flusso del client è
loopback nel browser di sistema, RFC 8252, vedi M2 — il redirect finale è verso Supabase, che è
un'app web).

1. <https://console.cloud.google.com/> → crea (o seleziona) un progetto, es. `autochess-of-ages`.
2. **APIs & Services → OAuth consent screen**:
   - User type: **External**.
   - App name: `Autochess Of Ages`, email di supporto, email developer.
   - **Scopes**: bastano quelli di default (`.../auth/userinfo.email`, `openid`,
     `.../auth/userinfo.profile`). Il trigger di primo login (M1) usa solo `name` dai metadati.
   - **Test users**: aggiungi il tuo indirizzo Google finché l'app è in "Testing". Per il lancio
     pubblico dovrai fare **Publish app** (la verifica Google non è richiesta con questi soli
     scope non sensibili).
3. **APIs & Services → Credentials → Create Credentials → OAuth client ID**:
   - Application type: **Web application**
   - Name: `supabase-auth`
   - **Authorized redirect URIs** → Add URI:

     ```
     https://<project-ref>.supabase.co/auth/v1/callback
     ```

     Questo è l'unico redirect URI necessario: Google torna a Supabase, e Supabase poi redirige
     al loopback `127.0.0.1` del client (che si configura in Supabase, passo 4 — non qui).
   - **Create**.
4. Copia **Client ID** (`<google-client-id>`) e **Client secret** (`<google-client-secret>`).

---

## 4. Supabase Auth — provider Google e Redirect URLs

### 4a. Abilitare Google

Dashboard Supabase → **Authentication → Sign In / Providers → Google**:

- **Enable Sign in with Google**: ON
- **Client IDs**: incolla `<google-client-id>`
- **Client Secret**: incolla `<google-client-secret>`
- **Callback URL (for OAuth)**: il campo mostra
  `https://<project-ref>.supabase.co/auth/v1/callback` — deve coincidere **esattamente** con
  quello messo in Google Cloud al passo 3.3. Se non coincide, correggilo in Google.
- **Save**.

### 4b. Redirect URLs per il flusso loopback + PKCE del client

Dashboard Supabase → **Authentication → URL Configuration**:

- **Site URL**: `https://game.tuodominio.it` (placeholder accettabile finché il dominio non è
  attivo; non influisce sul flusso nativo).
- **Redirect URLs** → **Add URL**, aggiungi entrambe queste voci:

  ```
  http://127.0.0.1
  http://127.0.0.1:*
  ```

  Il client (M2) apre un `TCPServer` su `127.0.0.1:<porta libera casuale>` e passa
  `redirect_to=http://127.0.0.1:<porta>/callback` nella richiesta di autorizzazione. Supabase
  accetta il redirect solo se combacia con questa allow-list; la wildcard `:*` copre la porta
  dinamica. Senza queste due righe il login fallisce con `redirect_to is not allowed`.

- **Save**.

> Nota: NON aggiungere qui `https://<project-ref>.supabase.co/...` — quello è il callback interno
> di Supabase verso Google, gestito automaticamente, non un redirect verso il client.

### 4c. (Opzionale ma consigliato) impostazioni token

**Authentication → Sign In / Providers → (in fondo) o Settings**:
- **Refresh token rotation**: ON
- **JWT expiry**: 3600 s (default) — il client fa il refresh con `user://auth.dat`.

---

## 5. CLI Supabase — link, push, sviluppo locale

### 5a. Installazione e login

```sh
npm i -g supabase
supabase --version
supabase login
```

`supabase login` apre il browser e genera un access token della CLI (diverso dalle chiavi del
progetto).

### 5b. Collegare il repo al progetto Frankfurt

Dalla root del repo (`C:\Users\afalc\Desktop\Projects\AtuochessOfAges`):

```sh
supabase link --project-ref <project-ref>
```

Chiede la **Database password** (`<db-password>` del passo 1). Questo crea/aggiorna
`supabase/.temp` e lega i comandi `db` al progetto remoto.

> Se la cartella di lavoro delle migrazioni è `db/` e non la `supabase/` di default, l'altro
> agente avrà impostato `db/config.toml` (da `supabase init`) con i path corretti, oppure il
> repo userà `--workdir db`. Adegua i comandi seguenti di conseguenza (es.
> `supabase db push --workdir db`).

### 5c. Applicare lo schema di M1 al progetto remoto

```sh
supabase db push
```

Applica `db/migrations/0001_initial.sql` (tabelle `profiles`, `player_stats`, `owned_civs`,
`match_history`; funzione `handle_new_user()` + trigger `on_auth_user_created`; `enable row level
security` e le policy di sola lettura sul proprio record). Verifica l'output: deve elencare
`0001_initial` come applicata, senza errori.

Controlla anche dal Dashboard → **Table Editor** che le 4 tabelle esistano, e → **Database →
Triggers** che `on_auth_user_created` sia su `auth.users`.

### 5d. Flusso locale (Docker) — per sviluppare senza toccare la produzione

Richiede Docker Desktop attivo.

```sh
supabase start
```

Avvia Postgres + Auth + Studio in locale. Alla fine stampa le credenziali locali:
- **API URL**: `http://localhost:54321`
- **Studio**: <http://localhost:54323>
- **anon key** / **service_role key** locali (diverse da quelle di produzione, usa queste per i
  test locali)
- **DB URL**: `postgresql://postgres:postgres@localhost:54322/postgres`

Riapplicare tutte le migrazioni da zero sul DB locale:

```sh
supabase db reset
```

Ricrea il database, riesegue tutte le migrazioni in `db/migrations/` e poi `db/seed.sql`. Deve
finire **senza errori**: è il criterio di accettazione di M1.

Per fermare tutto:

```sh
supabase stop
```

### 5e. Creare una nuova migrazione (per il futuro)

Non modificare `0001_initial.sql` dopo che è in produzione. Per cambiare lo schema:

```sh
supabase migration new nome_modifica
# scrivi il SQL nel file generato in db/migrations/
supabase db reset      # verifica in locale
supabase db push       # applica in produzione
```

---

## 6. Verifica della RLS

Obiettivo: dimostrare che (a) il trigger di primo login popola le tabelle, e (b) la `anon` key
da sola non legge niente.

### 6a. Creare un utente di test da Studio

Dashboard (o Studio locale) → **Authentication → Users → Add user → Create new user**:
- Email: `test@example.com`
- Password: una qualsiase
- **Auto Confirm User**: ON

> Questo NON passa dal provider Google, ma il trigger `on_auth_user_created` scatta comunque
> perché è su `auth.users` per ogni `insert`.

### 6b. Verificare le righe create dal trigger

Dashboard → **SQL Editor** (l'SQL Editor gira come `service_role`, quindi vede tutto):

```sql
select id, username, favourite_origin from public.profiles;
select profile_id, matches_played, wins, mmr from public.player_stats;
select profile_id, civ_id, source from public.owned_civs;
```

Atteso per l'utente di test:
- **1 riga** in `profiles` (username = il `name` di Google, oppure `player_<8 char>` per l'utente
  creato a mano)
- **1 riga** in `player_stats` (`mmr = 1000`, contatori a 0)
- **2 righe** in `owned_civs`: `roman` e `gaul`, entrambe `source = 'default'`

### 6c. Query REST con la sola `anon` key → deve tornare `[]`

Da terminale, sostituendo `<anon-key>` (produzione: passo 1; locale: output di `supabase start`)
e l'URL:

```sh
curl -s "https://<project-ref>.supabase.co/rest/v1/profiles?select=*" \
  -H "apikey: <anon-key>"
```

Locale:

```sh
curl -s "http://localhost:54321/rest/v1/profiles?select=*" \
  -H "apikey: <anon-key-locale>"
```

**Risultato atteso: `[]`** (array vuoto, zero righe).

Spiegazione: senza header `Authorization: Bearer <jwt>`, `auth.uid()` è `null`, quindi la policy
`using (auth.uid() = id)` non matcha nessuna riga. La chiave `anon` autentica la *richiesta* al
progetto, non l'*utente*.

Ripeti per le altre tabelle — devono tutte tornare `[]`:

```sh
for t in profiles player_stats owned_civs match_history; do
  echo -n "$t -> "
  curl -s "https://<project-ref>.supabase.co/rest/v1/$t?select=*" -H "apikey: <anon-key>"
  echo
done
```

`match_history` non ha **nessuna** policy → torna `[]` anche con un JWT valido: la legge solo il
server con la `service_role` key.

### 6d. (Controprova) con un JWT valido si vede solo il proprio record

Ottieni un `access_token` per l'utente di test:

```sh
curl -s "https://<project-ref>.supabase.co/auth/v1/token?grant_type=password" \
  -H "apikey: <anon-key>" -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"<password-di-test>"}'
```

Copia `access_token` dalla risposta, poi:

```sh
curl -s "https://<project-ref>.supabase.co/rest/v1/profiles?select=*" \
  -H "apikey: <anon-key>" \
  -H "Authorization: Bearer <access-token>"
```

Ora torna **1 riga** (solo il profilo di quell'utente). Se creassi un secondo utente, non lo
vedresti.

---

## 7. Piano Pro

Il **Free tier non basta per il lancio pubblico**:

- **Pausa per inattività**: il progetto Free viene **sospeso dopo ~7 giorni senza attività**.
  Alla prima connessione dopo la pausa il DB è irraggiungibile per qualche minuto mentre si
  risveglia — inaccettabile per un gioco live.
- **Niente Point-in-Time Recovery (PITR)**: sul Free ci sono solo backup giornalieri con
  retention breve. Un errore scoperto dopo 48 h non è recuperabile al minuto.
- Limiti su connessioni, storage e MAU più stretti.

**Piano Pro: ~25 $/mese** (include niente pausa, backup giornalieri con 7 giorni di retention,
PITR attivabile come add-on, 100k MAU). È una voce del costo a regime stimato in M7
(~35-40 €/mese totali con VPS + storage backup).

**Come fare l'upgrade**: Dashboard → **Settings → Billing → Subscription plan → Change plan →
Pro**. Inserisci il metodo di pagamento a livello di **Organization**. Fallo **prima** di
pubblicare l'app sul Play Store, non dopo.

Dopo l'upgrade, per PITR: **Settings → Add-ons → Point-in-Time Recovery** (costo aggiuntivo,
opzionale — il `pg_dump` notturno del VPS su Hetzner Storage Box, previsto in M7, è comunque un
secondo livello indipendente).

---

## 8. GDPR e cancellazione account

Gli utenti sono in UE. Due obblighi:

### 8a. Privacy policy (obbligatoria anche per il Play Store)

Serve una pagina pubblica raggiungibile (es. `https://game.tuodominio.it/privacy`) che dichiari:
- dati raccolti: email e nome Google, statistiche di gioco, cronologia partite;
- base giuridica, titolare del trattamento, finalità;
- provider: Supabase (Postgres in UE — Frankfurt), Google Sign-In;
- diritti dell'utente, incluso il diritto alla cancellazione e come esercitarlo;
- contatto per le richieste.

L'URL va inserito nella scheda del Play Store (**Play Console → Policy → App content → Privacy
policy**) e linkato dentro l'app (schermata impostazioni).

### 8b. Cancellazione account

La cancellazione è **una sola riga**: eliminare l'utente da `auth.users`. Tutto il resto è
`on delete cascade` (`profiles` → `player_stats`, `owned_civs`; `profiles.id` referenzia
`auth.users(id) on delete cascade`):

```sql
delete from auth.users where id = '<uuid-utente>';
```

> `match_history` **non** ha FK verso `profiles` (contiene un `jsonb results` con i `profile_id`),
> quindi le partite storiche restano ma con riferimenti a un profilo che non esiste più. Se serve
> anonimizzarle davvero, aggiungi in una migrazione futura una funzione che scrub-a i
> `profile_id` dal `jsonb` prima della delete.

**Come esporre la cancellazione all'utente** — due opzioni, entrambe usano la `service_role` key
lato server (mai dal client):

1. **Supabase Edge Function** (`delete-account`): l'app chiama la function col proprio JWT; la
   function estrae `sub` dal token, crea un client admin con la `service_role` key
   (`SUPABASE_SERVICE_ROLE_KEY` è già disponibile come secret nelle Edge Functions) e chiama
   `supabase.auth.admin.deleteUser(sub)`. Deploy:

   ```sh
   supabase functions new delete-account
   # scrivi la logica in supabase/functions/delete-account/index.ts
   supabase functions deploy delete-account
   ```

2. **Endpoint sul master server** (VPS): l'app manda un messaggio autenticato al master, che
   verifica il JWT (già lo fa per il matchmaking, M4), poi fa una `HTTPRequest` DELETE su
   `https://<project-ref>.supabase.co/auth/v1/admin/users/<sub>` con header
   `Authorization: Bearer <service_role_key>`. Riusa il codice di `net/supabase_client.gd` lato
   server.

L'opzione 1 è più semplice e non dipende dal VPS acceso. In entrambi i casi: conferma esplicita
nell'app ("Questa azione è irreversibile"), e dopo la delete forza il logout e cancella
`user://auth.dat`.

---

## 9. Checklist finale prima del deploy VPS

Deve essere tutto vero prima di iniziare M7.

**Progetto**
- [ ] Progetto Supabase creato in region **Frankfurt (eu-central-1)**
- [ ] `<db-password>` salvata in un password manager
- [ ] `SUPABASE_URL`, `anon` key e `service_role` key annotate in un posto sicuro

**Sicurezza chiavi**
- [ ] La `service_role` key **non** è nel repo (`git grep` non la trova), non è in `data/`, non
      è in `export_presets.cfg`, non è in nessun file di test
- [ ] `.gitignore` esclude `*.dat`, `**/service_role*` e simili
- [ ] Sul VPS (quando pronto): `/etc/autochess/env` mode `0600`, owner `root`, con
      `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `MATCH_TOKEN_SECRET`
- [ ] Nell'APK / repo c'è **solo** la `anon` key

**Google OAuth**
- [ ] OAuth Client ID tipo **Web application** creato in Google Cloud Console
- [ ] Authorized redirect URI = `https://<project-ref>.supabase.co/auth/v1/callback` (identico
      in Google e in Supabase)
- [ ] OAuth consent screen configurato; il proprio account è tra i Test users (o app pubblicata)

**Supabase Auth**
- [ ] Provider **Google** abilitato con Client ID + Client Secret
- [ ] Redirect URLs contengono `http://127.0.0.1` **e** `http://127.0.0.1:*`
- [ ] Refresh token rotation attiva

**Schema / CLI**
- [ ] `supabase login` fatto
- [ ] `supabase link --project-ref <project-ref>` fatto
- [ ] `supabase db push` applica `db/migrations/0001_initial.sql` senza errori
- [ ] `supabase start` + `supabase db reset` in locale finiscono senza errori
- [ ] Studio locale raggiungibile su <http://localhost:54323>
- [ ] Le 4 tabelle (`profiles`, `player_stats`, `owned_civs`, `match_history`) esistono in
      produzione
- [ ] Trigger `on_auth_user_created` presente su `auth.users`

**RLS**
- [ ] Utente di test creato da Studio → compaiono 1 `profiles` + 1 `player_stats` + 2
      `owned_civs` (`roman`, `gaul`, `default`)
- [ ] `curl` REST con la sola `anon` key su ogni tabella → `[]`
- [ ] `curl` REST con JWT valido su `profiles` → solo la propria riga
- [ ] `row level security` è `enabled` su tutte e 4 le tabelle (Table Editor mostra "RLS
      enabled")

**Billing / legale**
- [ ] Piano **Pro** attivo (prima della pubblicazione sul Play Store)
- [ ] Privacy policy pubblicata a un URL raggiungibile e linkata nell'app
- [ ] Meccanismo di cancellazione account implementato (Edge Function o endpoint master) e
      testato su un utente usa-e-getta

**Client (M2, verifica incrociata)**
- [ ] Permesso **INTERNET** aggiunto in `export_presets.cfg`
      (`permissions/custom_permissions`)
- [ ] `net/supabase_client.gd` legge `SUPABASE_URL` + `anon` key da `data/backend.json` (o
      `data/catalog.json`)
- [ ] Login Google su dispositivo reale: consenso nel browser → ritorno al gioco → sessione
      persiste dopo riavvio app
- [ ] Modalità aereo: l'app si apre, resta ospite, single-player funziona

---

### Comandi di riferimento rapido

```sh
# Installazione e collegamento
npm i -g supabase
supabase login
supabase link --project-ref <project-ref>

# Produzione
supabase db push

# Locale (Docker)
supabase start
supabase db reset
supabase stop

# Verifica RLS (deve tornare [])
curl -s "https://<project-ref>.supabase.co/rest/v1/profiles?select=*" -H "apikey: <anon-key>"

# Cancellazione account (SQL Editor, come service_role)
# delete from auth.users where id = '<uuid>';
```
