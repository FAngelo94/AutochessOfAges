# SELFHOST_PLAN.md — rimuovere Supabase, tutto dentro il VPS

Piano esecutivo per eliminare Supabase come dipendenza. Al termine il backend è
**Postgres + PostgREST + master + worker + Caddy su una sola macchina Hetzner**, e
l'unico servizio esterno che resta è Google (inevitabile: è l'identity provider del
login).

Prerequisito di lettura: `MULTIPLAYER_PLAN.md` (design del multiplayer),
`SETUP_VPS.md` (deploy attuale). Questo piano **sostituisce** `SETUP_SUPABASE.md`.

Stima onesta: **5–6 giorni** di lavoro pieno. Non è "solo l'OAuth": la parte lunga
sono lo schema, il layer dati del server e i nuovi messaggi di protocollo.

---

## D0 — Decisioni architetturali (leggere prima di toccare qualsiasi file)

### D0.1 Il vincolo che determina tutto: Godot non ha un driver Postgres

GDScript non può aprire una connessione al protocollo wire di Postgres. Non esiste
un modulo core né un addon affidabile per Godot 4.7. Quindi il server di gioco
**non può parlare direttamente al database**: serve un intermediario HTTP.

Scelta: **PostgREST** (binario statico singolo, ~30 MB, dalle release GitHub),
in ascolto **solo su `127.0.0.1:3000`**.

Perché PostgREST e non un sidecar Node/Python scritto a mano:

- `server/stats_writer.gd` e `server/supabase_admin.gd` **parlano già PostgREST**
  (`/rest/v1/rpc/...`, `/rest/v1/<tabella>?col=eq.val`). Cambiando solo l'URL base
  e togliendo gli header `apikey`, funzionano identici.
- La RPC `public.record_match_result(...)` di `0001_initial.sql` è SQL puro: gira
  sotto PostgREST esattamente come sotto Supabase.
- Zero runtime aggiuntivi da mantenere (niente Node, niente venv Python).

### D0.2 Il client non parla più HTTP col nostro backend

Oggi il client fa richieste HTTP a Supabase (`net/supabase_client.gd`: auth REST +
PostgREST su `profiles`). **Dopo questo piano il client apre solo `wss://` verso il
master.** Profilo e statistiche viaggiano come nuovi messaggi di protocollo.

Conseguenza diretta: **la RLS sparisce e non va sostituita.** Le policy
`auth.uid() = id` esistevano perché la `anon key` girava nell'APK e chiunque poteva
interrogare PostgREST. Ora PostgREST è raggiungibile solo da `127.0.0.1` e solo
master e worker lo interrogano. La protezione diventa **isolamento di rete + un
ruolo Postgres a privilegio minimo**, non le policy per riga.

### D0.3 Lo scambio del code OAuth avviene sul MASTER, non sul client

Google, per i client di tipo *Desktop app*, richiede `client_secret` nello scambio
del code anche con PKCE. Se lo scambio lo facesse il client, quel secret finirebbe
nell'APK.

Quindi: il client fa il giro nel browser e cattura il `code` sul loopback (come
oggi), poi **manda `code` + `code_verifier` al master** via WebSocket. Il master
tiene `GOOGLE_CLIENT_SECRET` in `/etc/autochess/env`, chiama
`https://oauth2.googleapis.com/token` e ottiene l'`id_token`.

### D0.4 Niente più verifica JWKS: `server/jwt_verifier.gd` si CANCELLA

Il master ottiene l'`id_token` **direttamente da Google su TLS**. Google documenta
esplicitamente che in questo caso la verifica della firma è superflua: basta
validare i claim `aud`, `iss`, `exp`. Il token non è mai passato per le mani del
client.

Spariscono quindi: le 219 righe di `jwt_verifier.gd` (codifica DER/SPKI a mano,
ricostruzione chiave RSA da JWK), e da `master_server.gd` tutto il blocco
`_refresh_jwks` / `_jwks_age` / `JWKS_REFRESH_SECONDS` / `_supabase_url()`.

### D0.5 La sessione è un token firmato dal master

Al posto del JWT Supabase, il master emette il **proprio** token di sessione:
HMAC-SHA256, stesso stile di `server/match_token.gd` (che resta invariato).

`Matchmaker` prende il verificatore per iniezione (`Matchmaker.new(_verifier)`,
"qualunque oggetto con `verify(token) -> Dictionary`"): basta iniettare
`SessionToken` invece di `JwtVerifier` e **`server/matchmaker.gd` non cambia**.

### D0.6 Architettura finale

```
Client (Godot)
  ├─ browser di sistema ──→ accounts.google.com          (solo il consenso)
  └─ wss://game.tuodominio.it/ws/mm ──→ Caddy :443
                                          │
─── VPS Hetzner ──────────────────────────┼──────────────────────────────
                                          ├─→ master  127.0.0.1:9000 ─┐
                                          └─→ worker1 127.0.0.1:9001 ─┤
                                                                      ↓
                                              PostgREST 127.0.0.1:3000
                                                                      ↓
                                              Postgres  127.0.0.1:5432
```

Nessuna porta oltre 22 e 443 è esposta. Come oggi.

---

## D1 — Schema Postgres senza Supabase

Nulla è ancora in produzione (`SETUP_SUPABASE.md` §7 dice di fare l'upgrade a Pro
"prima del lancio", quindi il DB è al più un progetto di prova). **Riscrivere
`db/migrations/0001_initial.sql`**, non aggiungere una `0002`.

### D1.1 Sostituire `db/migrations/0001_initial.sql`

Differenze rispetto alla versione attuale:

| Cosa | Prima (Supabase) | Dopo (self-host) |
|---|---|---|
| identità | `auth.users` gestita da GoTrue | colonne `google_sub`, `email` su `public.profiles` |
| primo login | trigger `on_auth_user_created` su `auth.users` | RPC `upsert_google_account(...)` chiamata dal master |
| RLS | 4 tabelle + 4 policy | **eliminata** (vedi D0.2) |
| grant | `anon`, `authenticated`, `service_role` | un solo ruolo `autochess_app` |
| sessioni | refresh token gestiti da GoTrue | tabella `public.sessions` |

Contenuto (i nomi delle 4 tabelle esistenti **non cambiano**, così il payload di
`stats_writer.gd` e la RPC `record_match_result` restano identici):

```sql
-- =============================================================================
-- 0001_initial.sql — Autochess Of Ages, schema self-hosted (Postgres 16)
-- =============================================================================
-- MODELLO DI SICUREZZA
-- Nessun client raggiunge questo database. PostgREST ascolta su 127.0.0.1:3000
-- e i soli chiamanti sono master e worker sulla stessa macchina. Non c'e' RLS
-- perche' non c'e' una chiave pubblica in circolazione da contenere.
-- Se un giorno il client tornasse a parlare HTTP col DB, la RLS va RIMESSA.
-- =============================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid()

create table public.profiles (
  id               uuid primary key default gen_random_uuid(),
  google_sub       text unique not null,          -- "sub" dell'id_token Google
  email            text,
  username         text unique not null,
  favourite_origin text not null default '',
  favourite_hero   text not null default '',
  created_at       timestamptz not null default now()
);

create table public.player_stats (
  profile_id     uuid primary key references public.profiles(id) on delete cascade,
  matches_played int not null default 0,
  wins           int not null default 0,
  top4           int not null default 0,
  mmr            int not null default 1000,
  updated_at     timestamptz not null default now()
);

create table public.owned_civs (
  profile_id  uuid references public.profiles(id) on delete cascade,
  civ_id      text not null,
  source      text not null,                      -- 'default' | 'purchase' | 'promo'
  acquired_at timestamptz not null default now(),
  primary key (profile_id, civ_id)
);

create table public.match_history (
  id         uuid primary key default gen_random_uuid(),
  match_id   text unique,
  seed       bigint not null,
  ranked     boolean not null default true,
  started_at timestamptz not null default now(),
  ended_at   timestamptz,
  results    jsonb not null default '[]'::jsonb
);

-- Refresh token opachi. Si salva solo lo sha256: un dump del DB non permette
-- di impersonare nessuno.
create table public.sessions (
  token_hash text primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index sessions_profile_idx on public.sessions (profile_id);
```

### D1.2 RPC `upsert_google_account`

Rimpiazza il trigger. Idempotente, atomica, restituisce tutto ciò che serve al
master per rispondere `AUTH_OK` in un colpo solo.

```sql
create function public.upsert_google_account(
  p_sub   text,
  p_email text,
  p_name  text
) returns jsonb
language plpgsql
as $$
declare
  v_id         uuid;
  v_base       text;
  v_final      text;
  v_suffix     int := 0;
begin
  select id into v_id from public.profiles where google_sub = p_sub;

  if v_id is null then
    v_base := coalesce(nullif(trim(p_name), ''), 'player_' || left(md5(p_sub), 8));
    -- username e' unique: due account Google possono avere lo stesso nome
    v_final := v_base;
    while exists (select 1 from public.profiles where username = v_final) loop
      v_suffix := v_suffix + 1;
      v_final := v_base || '_' || v_suffix::text;
    end loop;

    insert into public.profiles (google_sub, email, username)
      values (p_sub, p_email, v_final)
      returning id into v_id;
    insert into public.player_stats (profile_id) values (v_id);
    insert into public.owned_civs (profile_id, civ_id, source)
      values (v_id, 'roman', 'default'), (v_id, 'gaul', 'default');
  else
    update public.profiles set email = coalesce(p_email, email) where id = v_id;
  end if;

  return (
    select jsonb_build_object(
      'id',       p.id,
      'username', p.username,
      'profile',  jsonb_build_object(
                    'favourite_origin', p.favourite_origin,
                    'favourite_hero',   p.favourite_hero),
      'stats',    jsonb_build_object(
                    'matches_played', s.matches_played,
                    'wins', s.wins, 'top4', s.top4, 'mmr', s.mmr),
      'owned_civs', coalesce(
                    (select jsonb_agg(c.civ_id) from public.owned_civs c
                      where c.profile_id = p.id), '[]'::jsonb))
    from public.profiles p
    join public.player_stats s on s.profile_id = p.id
    where p.id = v_id);
end $$;
```

### D1.3 RPC per i refresh token

```sql
create function public.store_refresh_token(
  p_profile uuid, p_hash text, p_ttl_days int
) returns void
language sql as $$
  insert into public.sessions (token_hash, profile_id, expires_at)
  values (p_hash, p_profile, now() + make_interval(days => p_ttl_days));
$$;

-- Rotazione: consuma il vecchio hash e ritorna il bundle del profilo, oppure
-- null se il token e' assente/scaduto. Atomica.
create function public.redeem_refresh_token(p_hash text) returns jsonb
language plpgsql as $$
declare v_id uuid;
begin
  delete from public.sessions
    where token_hash = p_hash and expires_at > now()
    returning profile_id into v_id;
  if v_id is null then
    return null;
  end if;
  return (
    select jsonb_build_object(
      'id', p.id, 'username', p.username,
      'profile', jsonb_build_object(
        'favourite_origin', p.favourite_origin, 'favourite_hero', p.favourite_hero),
      'stats', jsonb_build_object(
        'matches_played', s.matches_played, 'wins', s.wins,
        'top4', s.top4, 'mmr', s.mmr),
      'owned_civs', coalesce(
        (select jsonb_agg(c.civ_id) from public.owned_civs c where c.profile_id = p.id),
        '[]'::jsonb))
    from public.profiles p join public.player_stats s on s.profile_id = p.id
    where p.id = v_id);
end $$;

-- igiene: chiamata dal cron notturno
create function public.purge_expired_sessions() returns void
language sql as $$ delete from public.sessions where expires_at < now(); $$;
```

### D1.4 `record_match_result` — invariata tranne i grant

Copiare **identica** la funzione da `0001_initial.sql` attuale (righe 128–167).
Cambia solo la riga finale dei grant:

```sql
revoke all on function public.record_match_result(text, bigint, boolean, jsonb) from public;
```

(il grant a `autochess_app` sta in D1.5, insieme agli altri)

### D1.5 Ruoli e grant — in fondo alla migrazione

```sql
-- autochess_app: il ruolo con cui gira ogni query di master e worker.
-- autochess_auth: ruolo di connessione di PostgREST (NOINHERIT, fa SET ROLE).
-- Le password vanno sostituite al deploy (vedi SETUP_DB.md).
create role autochess_app  nologin;
create role autochess_auth noinherit login password 'CHANGE_ME';
grant autochess_app to autochess_auth;

revoke all on schema public from public;
grant usage on schema public to autochess_app;

grant select, update (favourite_origin, favourite_hero) on public.profiles to autochess_app;
grant select on public.player_stats, public.owned_civs to autochess_app;
grant select, insert on public.match_history to autochess_app;
grant select, insert, delete on public.sessions to autochess_app;

grant execute on function public.upsert_google_account(text, text, text)          to autochess_app;
grant execute on function public.store_refresh_token(uuid, text, int)             to autochess_app;
grant execute on function public.redeem_refresh_token(text)                       to autochess_app;
grant execute on function public.purge_expired_sessions()                         to autochess_app;
grant execute on function public.record_match_result(text, bigint, boolean, jsonb) to autochess_app;
```

> Nota: `record_match_result` scrive `player_stats`, su cui `autochess_app` ha solo
> `select`. Perché funzioni, dichiarare la funzione **`security definer`** (già lo è
> nella versione attuale) e assicurarsi che il proprietario sia il ruolo che ha creato
> le tabelle. Stesso discorso per `upsert_google_account`, `store_refresh_token`,
> `redeem_refresh_token`: aggiungere `security definer set search_path = public` a
> ciascuna.

### D1.6 File di contorno

- **Cancellare** `db/config.toml` (era la config della CLI Supabase).
- **Aggiungere** `db/apply.sh`: applica in ordine i file di `db/migrations/` con
  `psql`, tracciando quelli già applicati in una tabella `public.schema_migrations
  (filename text primary key, applied_at timestamptz default now())`.
- **Aggiungere** `db/docker-compose.dev.yml`: `postgres:16` + `postgrest:v12` per lo
  sviluppo locale su Windows, in sostituzione di `supabase start`.
- **Riscrivere** `db/README.md`: togliere la tabella "chi legge / chi scrive" basata
  su RLS, togliere i comandi `supabase`, documentare `apply.sh` e il compose di dev.

**Accettazione D1**: `db/apply.sh` su un Postgres vuoto finisce senza errori;
`select public.upsert_google_account('sub-test','a@b.c','Tizio')` chiamata due volte
restituisce lo stesso `id` e lascia 1 riga in `profiles`, 1 in `player_stats`, 2 in
`owned_civs`.

---

## D2 — Postgres e PostgREST sul VPS

### D2.1 Installazione

```sh
sudo apt install -y postgresql-16 postgresql-client-16
sudo -u postgres createdb autochess
```

In `/etc/postgresql/16/main/postgresql.conf` verificare
`listen_addresses = 'localhost'` (è il default Debian/Ubuntu — **confermarlo**, non
darlo per scontato).

PostgREST (binario statico, nessun runtime):

```sh
cd /tmp
curl -LO https://github.com/PostgREST/postgrest/releases/download/v12.2.3/postgrest-v12.2.3-linux-static-x64.tar.xz
tar -xJf postgrest-v12.2.3-linux-static-x64.tar.xz
sudo install -o root -g root -m 755 postgrest /usr/local/bin/postgrest
postgrest --version
```

### D2.2 `deploy/postgrest.conf`

```
db-uri        = "postgres://autochess_auth:<PASSWORD>@127.0.0.1:5432/autochess"
db-schemas    = "public"
db-anon-role  = "autochess_app"
server-host   = "127.0.0.1"
server-port   = 3000
db-pool       = 8
```

Installare come `/etc/autochess/postgrest.conf`, mode `0600`, owner `root`
(contiene la password del DB).

### D2.3 `deploy/autochess-postgrest.service`

Nuova unit systemd, sullo stampo di quelle esistenti:

```ini
[Unit]
Description=PostgREST (accesso dati Autochess)
After=postgresql.service
Requires=postgresql.service

[Service]
User=autochess
Group=autochess
ExecStart=/usr/local/bin/postgrest /etc/autochess/postgrest.conf
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

Aggiornare `deploy/autochess-master.service` e `deploy/autochess-worker@.service`
con `After=autochess-postgrest.service` e `Requires=autochess-postgrest.service`.

### D2.4 Caddy — nessuna modifica

`deploy/Caddyfile` resta **identico**: PostgREST non è esposto. Le sole route
pubbliche restano `/ws/mm` e `/ws/wN`.

### D2.5 `deploy/env.example` — riscrivere

Rimuovere `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_DB_URL`.
Aggiungere:

```sh
# Base URL di PostgREST (loopback: mai esposto)
DB_API_URL=http://127.0.0.1:3000

# OAuth Google — client di tipo "Desktop app" (Google Cloud Console).
# Il client_secret di un client "installed app" NON e' un vero segreto secondo
# Google, ma lo teniamo comunque solo qui e mai nell'APK: lo scambio del code
# lo fa il master.
GOOGLE_CLIENT_ID=xxxxxxxx.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-xxxxxxxx

# Segreto HMAC dei token di SESSIONE emessi dal master. openssl rand -hex 32
# Distinto da MATCH_TOKEN_SECRET: ruoli e durate diversi.
SESSION_TOKEN_SECRET=replace-with-openssl-rand-hex-32

# (invariato) firma dei match_token e degli SPAWN_MATCH master->worker
MATCH_TOKEN_SECRET=replace-with-openssl-rand-hex-32

MASTER_ENFORCE_ROSTER=0

# --- backup ---
BACKUP_DB_URL=postgresql://postgres@127.0.0.1:5432/autochess
BACKUP_SSH_TARGET=uXXXXXX@uXXXXXX.your-storagebox.de:/home/backups/autochess
BACKUP_SSH_PORT=23
```

**Accettazione D2**:
`curl -s 'http://127.0.0.1:3000/profiles?select=id' -H 'Accept: application/json'`
risponde `[]` (o le righe di test) **dal VPS**; la stessa richiesta da fuori va in
timeout.

---

## D3 — Layer dati del server

### D3.1 Nuovo `server/db_client.gd` (sostituisce `server/supabase_admin.gd`)

`class_name DbClient`. Stessa forma statica di `SupabaseAdmin` (`owner: Node` per
l'`HTTPRequest`, callback `cb.call(ok, dati)`), ma:

- base URL da `OS.get_environment("DB_API_URL")`, default `http://127.0.0.1:3000`;
- **nessun header** `apikey` / `Authorization`;
- percorsi senza il prefisso `/rest/v1` (PostgREST espone `/profiles`, `/rpc/foo`).

Funzioni richieste:

```gdscript
static func is_configured() -> bool
static func fetch_owned_civs(owner: Node, uid: String, cb: Callable) -> void
static func upsert_google_account(owner: Node, sub: String, email: String, name: String, cb: Callable) -> void
static func redeem_refresh_token(owner: Node, token_hash: String, cb: Callable) -> void
static func store_refresh_token(owner: Node, uid: String, token_hash: String, ttl_days: int, cb: Callable) -> void
static func update_preferences(owner: Node, uid: String, fields: Dictionary, cb: Callable) -> void
```

Le RPC si chiamano con `POST <base>/rpc/<nome>` e corpo JSON dei parametri
(`{"p_sub": ..., "p_email": ..., "p_name": ...}`).

Poi **cancellare `server/supabase_admin.gd`** e aggiornare le due chiamate in
`server/master_server.gd:169,176` a `DbClient`.

### D3.2 `server/stats_writer.gd` — modifica minima

Sostituire le sole righe di configurazione e header:

- `const RPC_PATH := "/rpc/record_match_result"` (era `/rest/v1/rpc/...`)
- `const HISTORY_PATH := "/match_history"` (era `/rest/v1/match_history`)
- `url` da `DB_API_URL` invece di `SUPABASE_URL`
- togliere `"apikey: " + key` e `"Authorization: Bearer " + key` da entrambi gli
  array di header; tenere `Content-Type` e `Prefer: return=minimal`
- il no-op quando la config manca resta: serve ai test headless

Aggiornare il commento di testa: non c'è più service_role né RLS da bypassare.

### D3.3 Cancellare `server/jwt_verifier.gd`

E in `server/master_server.gd` rimuovere: `JWKS_REFRESH_SECONDS`, `BACKEND_CONFIG`,
`_verifier := JwtVerifier.new()`, `_jwks_age`, `_supabase_url_cached`,
`_refresh_jwks()`, `_supabase_url()`, e le relative chiamate in `_process()`.

**Accettazione D3**: sul VPS, a partita finita, `select * from match_history` e
`select * from player_stats` mostrano la riga scritta dal worker.

---

## D4 — Autenticazione Google diretta

### D4.1 Google Cloud Console

Creare un **nuovo** OAuth Client ID di tipo **Desktop app** (non "Web
application": il redirect è ora `http://127.0.0.1:<porta>/callback`, che i client
Web non accettano con porta arbitraria). Il vecchio client con redirect verso
Supabase si può eliminare.

> Verificare sul consent screen che gli scope siano `openid`, `email`, `profile`.

### D4.2 `server/session_token.gd`

`class_name SessionToken`. Ricalcato su `server/match_token.gd`, HMAC-SHA256 con
`SESSION_TOKEN_SECRET`, TTL lungo (7 giorni).

```gdscript
const DEFAULT_TTL := 604800   # 7 giorni

static func mint(uid: String, username: String, now_unix: int = -1, ttl: int = DEFAULT_TTL) -> String
## Ritorna {"sub": uid, "name": username, "exp": int} oppure {} se firma
## invalida o scaduto. Firma compatibile con l'interfaccia che Matchmaker
## si aspetta dal verificatore iniettato.
static func verify(token: String, now_unix: int = -1) -> Dictionary
```

Formato: `"<uid>|<username_b64url>|<exp>|<sig_b64>"` — l'username va codificato
perché può contenere `|`.

In `server/master_server.gd`: `var _verifier := SessionToken.new()` — oppure, se
resta statico, un piccolo wrapper `RefCounted` con `verify()` d'istanza, perché
`Matchmaker.new(_verifier)` chiama `verifier.verify(token)`. **`matchmaker.gd` non
si tocca.**

### D4.3 `server/google_oauth.gd`

`class_name GoogleOAuth`. Scambia il code con Google e valida i claim.

```gdscript
## POST https://oauth2.googleapis.com/token
##   grant_type=authorization_code, code, code_verifier, redirect_uri,
##   client_id=$GOOGLE_CLIENT_ID, client_secret=$GOOGLE_CLIENT_SECRET
## (corpo application/x-www-form-urlencoded, NON JSON)
##
## cb.call(ok: bool, claims: Dictionary)  -> {sub, email, name}
static func exchange_code(owner: Node, code: String, verifier: String,
        redirect_uri: String, cb: Callable) -> void
```

Controlli obbligatori prima di considerare valido l'`id_token`:

1. `redirect_uri` deve essere **loopback**: `http://127.0.0.1:<porta>/callback`.
   Rifiutare qualsiasi altro host — altrimenti il master diventa un oracolo di
   scambio code per redirect arbitrari.
2. decodificare il payload dell'`id_token` (base64url, come già fa
   `net/auth.gd::_sub_from_jwt`);
3. `aud == GOOGLE_CLIENT_ID`;
4. `iss` in `{"accounts.google.com", "https://accounts.google.com"}`;
5. `exp` non scaduto;
6. `sub` non vuoto.

La firma **non** si verifica: vedi D0.4.

### D4.4 `server/account_service.gd`

Orchestrazione, chiamata dal master alla ricezione di `AUTH_GOOGLE` / `AUTH_REFRESH`:

```gdscript
## AUTH_GOOGLE: exchange_code -> upsert_google_account -> mint session
##              -> genera refresh opaco -> store_refresh_token
## cb.call(ok: bool, bundle: Dictionary)
##   bundle = {session_token, refresh_token, user_id, username, profile, stats, owned_civs}
static func login_google(owner: Node, code: String, verifier: String,
        redirect_uri: String, cb: Callable) -> void

## AUTH_REFRESH: sha256(refresh) -> redeem_refresh_token (rotazione)
##               -> mint session -> nuovo refresh -> store
static func refresh(owner: Node, refresh_token: String, cb: Callable) -> void
```

Il refresh token è **opaco**: 32 byte da `Crypto.generate_random_bytes(32)`,
esadecimale. Nel DB va solo `sha256(token)` in esadecimale.

**Accettazione D4**: test unitario in `tests/run_tests.gd` —
`SessionToken.verify(SessionToken.mint("u1","Tizio"))` ritorna
`{"sub":"u1","name":"Tizio",...}`; un token con un byte alterato ritorna `{}`; un
token con `exp` nel passato ritorna `{}`.

---

## D5 — Protocollo: auth e profilo sul WebSocket

### D5.1 Nuovi messaggi in `net/protocol.gd`

```gdscript
# --- client -> master (auth) ---
const AUTH_GOOGLE   := "AUTH_GOOGLE"    # {code, code_verifier, redirect_uri}
const AUTH_REFRESH  := "AUTH_REFRESH"   # {refresh_token}
const PROFILE_SET   := "PROFILE_SET"    # {favourite_origin, favourite_hero}

# --- master -> client ---
const AUTH_OK   := "AUTH_OK"    # {session_token, refresh_token, user_id,
                                #  username, profile, stats, owned_civs}
const AUTH_FAIL := "AUTH_FAIL"  # {reason}
const PROFILE_OK := "PROFILE_OK" # {}
```

Alzare `PROTOCOL_VERSION` a `2`.

`HELLO {protocol_version, access_token}` resta **invariato come forma**: cambia solo
cosa c'è dentro `access_token` (token di sessione del master invece del JWT
Supabase). Lo stesso vale per `net/dev_net.gd`, che continua a funzionare
identico in guest mode.

### D5.2 Gestione nel master

I messaggi `AUTH_*` e `PROFILE_SET` sono **asincroni** (richiedono HTTP verso Google
e PostgREST) mentre `Matchmaker` è sincrono e testabile in-process. Per non
sporcarlo:

- gestire `AUTH_GOOGLE`, `AUTH_REFRESH`, `PROFILE_SET` **in `master_server.gd`**,
  prima di passare il pacchetto a `mm.handle_packet()`;
- `master_server.gd` ha già `_pump` (Node vivo) per gli `HTTPRequest` e
  `_peer.set_target_peer()` + `put_packet()` per rispondere a un peer singolo;
- un peer che fa solo auth e poi si disconnette non entra mai in coda: `Matchmaker`
  non lo vede.

`PROFILE_SET` richiede un peer già autenticato: verificare il token di sessione
prima di scrivere.

### D5.3 Riscrivere `net/auth.gd`

Il flusso loopback + PKCE (righe 77–183: `TCPServer`, `_extract_code`,
`_random_verifier`, `_sha256`, `_base64url`) **si tiene tutto**. Cambia:

| Riga oggi | Modifica |
|---|---|
| `var _client: SupabaseClient` | rimosso, sostituito da una connessione `WebSocketPeer` verso il master |
| URL authorize (`_client.supabase_url + /auth/v1/authorize?provider=google...`) | `https://accounts.google.com/o/oauth2/v2/auth?client_id=<id>&redirect_uri=<loopback>&response_type=code&scope=openid%20email%20profile&code_challenge=<c>&code_challenge_method=S256` |
| `_client.token_from_pkce(code, verifier, cb)` | `AUTH_GOOGLE {code, code_verifier, redirect_uri}` sul WS |
| `_client.token_from_refresh(rt, cb)` | `AUTH_REFRESH {refresh_token}` sul WS |
| `_sub_from_jwt(access_token)` | `user_id` arriva dentro `AUTH_OK`, non si decodifica più nulla |

`Auth` apre una WS **breve** verso `wss://<game_host>/ws/mm` solo per l'auth e la
chiude ricevuto `AUTH_OK`. `RemoteSession` continua ad aprire la sua, indipendente,
e a mandare `HELLO` con `Auth.access_token()` (ora il token di sessione).

Il degrado a ospite resta identico: se `data/backend.json` ha i segnaposto, se non
c'è rete, o se il refresh fallisce, si resta OSPITI in silenzio e il single-player
non se ne accorge.

**Aggiungere** un campo pubblico `owned_civs: PackedStringArray` e `stats:
Dictionary` popolati da `AUTH_OK`, che oggi non esistono lato client.

### D5.4 Cancellare `net/supabase_client.gd`

Nessun sostituto: il client non fa più richieste HTTP verso il backend.

**Accettazione D5**: `tests/net_smoke.gd` continua a passare iniettando un
verificatore finto (il punto di iniezione non è cambiato). Aggiungere un caso che
verifica il round-trip `AUTH_REFRESH` → `AUTH_OK` con un `DbClient` finto.

---

## D6 — Client: profilo e configurazione

### D6.1 `app/profile.gd`

Rimuovere `var _supabase: SupabaseClient` e le tre funzioni
`_remote_ready()` / `_pull_remote_preferences()` / `_push_remote_preferences()`
nella forma attuale. Sostituire con:

- `_pull_remote_preferences()`: legge `favourite_origin` / `favourite_hero` dal
  bundle già arrivato in `AUTH_OK` (esposto da `Auth`), **nessuna richiesta di
  rete**;
- `_push_remote_preferences()`: chiede ad `Auth` di inviare `PROFILE_SET` sul WS.

Il resto (`load_profile`, `save_profile`, `seen_tips`, velocità) è invariato: resta
locale al dispositivo come oggi.

### D6.2 `data/backend.json`

```json
{
  "_comment": "Backend self-hosted. Nessuna chiave segreta qui: il google_client_id e' pubblico per definizione e lo scambio del code lo fa il master.",
  "game_host": "game.tuodominio.it",
  "google_client_id": "REPLACE_WITH_GOOGLE_CLIENT_ID"
}
```

Rimuovere `supabase_url` e `anon_key`. Aggiornare il controllo "segnaposto" (era
`is_configured()` in `supabase_client.gd`): ora sta in `net/auth.gd` e verifica
`game_host` != `game.tuodominio.it` e `google_client_id` != il segnaposto.

**Accettazione D6**: `godot --headless --path . --script res://tests/auth_smoke.gd`
passa; con `backend.json` ai segnaposto l'app resta ospite e il single-player gira.

---

## D7 — Backup, cron, documentazione

### D7.1 `deploy/backup-db.sh`

- `SUPABASE_DB_URL` → `BACKUP_DB_URL` (`postgresql://postgres@127.0.0.1:5432/autochess`);
- il resto (`pg_dump | gzip`, controllo dimensione minima, `scp` sulla Storage Box,
  retention remota) è **invariato**;
- aggiornare i commenti di testa: non è più "il Postgres di Supabase".

Il backup ora è **l'unico** che esiste: prima c'erano anche quelli interni di
Supabase. La prova di restore di `SETUP_VPS.md` §10 diventa **obbligatoria**, non
consigliata.

### D7.2 Cron

Aggiungere al crontab di `autochess`:

```
23 4 * * *  psql -d autochess -c 'select public.purge_expired_sessions();' >/dev/null
```

### D7.3 Documentazione

- **Cancellare** `SETUP_SUPABASE.md`.
- **Creare** `SETUP_DB.md`: installazione Postgres + PostgREST, creazione ruoli e
  password, `db/apply.sh`, creazione del client OAuth Google "Desktop app",
  compilazione di `/etc/autochess/env`, verifica end-to-end.
- **Aggiornare** `SETUP_VPS.md`: §7 (nuove variabili), §9 (unit PostgREST), §10
  (backup locale), §13 (costi: **solo il VPS**), e togliere ogni riferimento a
  Supabase e al prerequisito `SETUP_SUPABASE.md`.
- **Aggiornare** `CLAUDE.md`: la riga `net/auth.gd` ("Google Sign-In via Supabase"),
  la tabella dei file (via `jwt_verifier.gd` e `supabase_admin.gd`, dentro
  `db_client.gd`, `session_token.gd`, `google_oauth.gd`, `account_service.gd`), la
  descrizione di `db/`.
- **Aggiornare** `MULTIPLAYER_PLAN.md`: M1/M2 descrivono Supabase Auth + RLS.

### D7.4 Costi dopo il piano

| Voce | Prima | Dopo |
|---|---|---|
| VPS Hetzner | ~8 € (CPX21) | ~8 € (CPX21 basta: Postgres + PostgREST occupano poco) |
| Supabase Pro | ~23 € | **0 €** |
| Storage Box BX11 | ~3 € | ~3 € |
| Dominio | ~1 € | ~1 € |
| **Totale/mese** | **~35 €** | **~12 €** |

---

## D8 — Verifica finale

```sh
# 1. schema pulito da zero
db/apply.sh   # su un DB vuoto, senza errori

# 2. test headless (il determinismo e' il piu' importante: non deve cambiare nulla)
godot --headless --path . --script res://tests/run_tests.gd
godot --headless --path . --script res://tests/net_smoke.gd
godot --headless --path . --script res://tests/auth_smoke.gd
godot --headless --path . --script res://tests/ui_smoke.gd -- --seed=4242

# 3. nessun residuo di Supabase nel repo
grep -ri "supabase\|service_role\|anon_key" --include='*.gd' --include='*.json' \
     --include='*.sql' --include='*.sh' .    # deve non trovare nulla

# 4. il DB non e' raggiungibile da fuori
nmap -Pn -p 3000,5432 game.tuodominio.it     # entrambe "filtered"
```

Prova finale su dispositivo reale: login Google → il gioco riceve `AUTH_OK` →
la sessione sopravvive al riavvio dell'app (refresh token) → due dispositivi in
coda → partita a 8 → `player_stats` aggiornate a fine partita.

---

## Cosa si perde rispetto a Supabase (accettarlo consapevolmente)

1. **Niente PITR.** Il ripristino massimo è all'ultimo `pg_dump` notturno: si
   possono perdere fino a 24 h di partite. Mitigabile alzando la frequenza del cron.
2. **Sei tu il DBA.** Patch di sicurezza di Postgres e PostgREST, `unattended-upgrades`
   copre il primo ma non il secondo (binario installato a mano): metterlo in
   calendario.
3. **Single point of failure.** DB, auth e gioco sulla stessa macchina: un riavvio li
   butta giù insieme. `Restart=always` copre i crash, non il downtime dell'host.
4. **Nessun cruscotto.** Le ispezioni si fanno con `psql`. Se serve una UI,
   `pgweb` (binario singolo) dietro `basic_auth` di Caddy su una route dedicata.
5. **La RLS non c'è più.** Se un domani il client dovesse tornare a parlare HTTP col
   database, la RLS va rimessa **prima**, non dopo (vedi il commento in testa a
   `0001_initial.sql`).
