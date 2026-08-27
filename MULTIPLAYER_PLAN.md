# Piano di implementazione — Multiplayer online 8 giocatori

> **Come usare questo documento.** È un piano operativo diviso in 8 milestone sequenziali (M0→M7).
> Ogni milestone ha: obiettivo, file da toccare, task concreti, e **criteri di accettazione**
> verificabili. Non passare alla milestone successiva finché i criteri di accettazione della
> corrente non sono soddisfatti. Le firme delle funzioni indicate sono vincolanti: rispettarle
> alla lettera, perché le milestone successive ci contano sopra.

---

## Stato di avanzamento

**M0–M7 implementate** sul branch `feature/multiplayer`. Test: `run_tests` 112/0,
`net_smoke` 71/0, `auth_smoke` 10/0. (`menu_smoke` 44/1 e `ui_smoke` 31/2: le
3 failure preesistono al lavoro multiplayer — stato locale di `user://profile.cfg`.)

**Hardening post-M7 completato:**
- **A1** il master apre una nuova lobby dopo ogni sigillo (`Matchmaker.sealed` →
  `master_server._on_mm_sealed`), non più una sola partita per riavvio.
- **A2** `SPAWN_MATCH` è firmato HMAC (`MatchToken.sign_control` / `verify_control`,
  campo `spawn_sig`); il worker rifiuta quelli non firmati dal master.
- **A3** `hero_id` sanificato contro `data/heroes.json` in `Matchmaker`
  (`_sanitize_hero`), più `hero_review` + `override_hero` + `server/supabase_admin.gd`
  per il controllo asincrono su `owned_civs` (enforce solo con
  `MASTER_ENFORCE_ROSTER=1`, dato che nel design attuale l'origin dell'hero è
  solo estetica).
- **A4** `ui/main.gd._on_command_rejected` copre i motivi del server remoto.
- **A6** `master_server` riscarica la JWKS ogni ora (rollover chiavi); guard su
  richieste sovrapposte in `JwtVerifier`.
- **A5** spectate online: `MatchSession.request_spectate()` + segnale
  `spectate_ready`; `LocalSession` risponde sincrono dai propri log, `RemoteSession`
  manda `SPECTATE_REQUEST` e riceve `SPECTATE_DATA` (ora con `team` e
  `opponent_hero_id`). `ui/main._open_spectate` usa l'unico percorso.
- **A7** `build_matchups()` evita gli avversari degli ultimi
  `REMATCH_AVOID_WINDOW` (=2) round con una scelta greedy deterministica sullo
  shuffle; consumo dello SimRNG invariato.

**Ancora aperti:** niente di bloccante. Nice-to-have: MMR reale (oggi `player_stats`
tiene solo matches/wins/top4), cache su disco della JWKS.

**Infrastruttura:** da fare a mano seguendo `SETUP_SUPABASE.md` e `SETUP_VPS.md`
(progetto Supabase, `supabase db push`, VPS, DNS, Caddy, systemd, backup).

---

## 0. Contesto e stato attuale

Il gioco oggi è single-player: `ui/main.gd:971` costruisce `MatchState` **sul client**, i 7
avversari sono bot guidati da `BotBrain`, e il profilo vive in `user://profile.cfg`.

L'obiettivo è: un giocatore sceglie "Contro giocatori", si logga con Google, entra in coda; dopo
**30 secondi** (o al raggiungimento di 8 giocatori) parte una partita su un **server autoritativo**
ospitato su un VPS; gli slot mancanti sono riempiti da bot. Statistiche e account su **Supabase**.

### Cosa c'è già (verificato, non dare per scontato il contrario)

| Fatto | Dove |
|---|---|
| `core/` è interamente `RefCounted`: zero Node, zero UI, zero autoload | l'unico riferimento a `Profile` in `core/` è dentro un **commento**, `core/player.gd:17` |
| Il match è **già a 8 giocatori** | `data/balance.json` → `match.players: 8`. Il single-player è solo `MatchState.new(seed, human_players=1)` |
| Il timer di preparazione **esiste già nei dati** | `data/balance.json` → `rounds.preparation_seconds: 30.0`, `first_round_preparation_seconds: 45.0` |
| `MatchState` è guidato a comandi espliciti, non a tempo | `start_round()` / `resolve_round()`. Oggi il "tick owner" è il bottone COMBATTI, `ui/main.gd:986` |
| `MatchState.preparation_seconds()` è **codice morto** | `core/match_state.gd:67` — zero chiamanti oggi. In M5 trova il suo chiamante |
| Il combattimento produce già un log rigiocabile | `CombatSim.result()` → `{initial, events, ...}`; `ui/combat_view.gd` lo rigioca **senza simulare** |
| RNG deterministico scritto a mano | `core/rng.gd`, xorshift64* con `get_state()`/`set_state()`/`fork(salt)`. **Nessun** `randi()`/`randf()`/`shuffle()` nativo in tutto il repo |
| Il pool è già condiviso e conteso | un solo `UnitPool` creato in `core/match_state.gd:33`, passato a tutti i `Player` |
| Il ramo PVP nel menu esiste come stub | `ui/menu.gd:930` apre un `AcceptDialog` "In arrivo" |
| `Store.user_id()` è il seam previsto per l'account online | `monetization/store.gd:55`, oggi `OS.get_unique_id()` |
| **Non esiste una sola riga di networking** | zero occorrenze di `WebSocket`, `ENet`, `HTTPRequest`, `@rpc`, `multiplayer.` nel repo |

### Cosa manca davvero

1. Un **layer di serializzazione** in `core/` (`to_dict`/`apply_dict`).
2. Un **trasporto** (WebSocket) e un **protocollo**.
3. Un **processo server** che possieda il tick e validi i comandi.
4. L'**autenticazione** e la persistenza remota.

### Decisioni già prese — non rimetterle in discussione

| Scelta | Valore |
|---|---|
| Login | **Google Sign-In** via Supabase OAuth |
| Single-player | **resta, offline e senza login.** Nessuna regressione ammessa |
| Master server | **Godot headless (GDScript)** — un solo stack, riusa `core/` |
| Trasporto | **WebSocket** (`wss://`), TLS terminato da Caddy |
| Serializzazione | **`var_to_bytes()` / `bytes_to_var()`**, non JSON |
| VPS | Hetzner Falkenstein/Norimberga (~15-25 ms dall'Italia) |
| Supabase | region **Frankfurt** |
| `roster_mode` | resta **`shared`** — le civiltà acquistate non danno vantaggio |

### Invarianti — valgono per ogni milestone

1. **`core/` non conosce `ui/` né la rete.** Il codice di rete sta in `net/` e `server/`. `core/`
   guadagna solo metodi di serializzazione puri.
2. **Il client non simula mai, online.** Non calcola shop, non tira dadi, non risolve combattimenti.
   Riceve snapshot e log di eventi. Questo elimina in un colpo il rischio dei float non
   deterministici cross-platform e la maggior parte del cheating.
3. **Il client non riceve mai lo stato privato altrui.** Shop, gold e panchina degli avversari non
   vanno sul filo. Mai.
4. **Nessuna feature di gioco dipende dal negozio** (vedi `monetization/README.md`).
5. **Il single-player offline continua a funzionare senza login e senza rete.**
6. **Il test di determinismo in `tests/run_tests.gd` non deve mai rompersi.** Se si rompe, l'autorità
   del server e i numeri di bilanciamento perdono senso: fermarsi e sistemare prima di proseguire.

### Perché queste scelte tecniche

**WebSocket e non ENet/UDP** — su rete mobile italiana alcuni operatori degradano o bloccano UDP.
Un autobattler non è latency-critical: i round sono a turni e il combattimento è **precalcolato dal
server e rigiocato dal client** dall'event log, quindi il ritardo TCP è irrilevante. In cambio:
passa da qualsiasi NAT/firewall, TLS gratis con Caddy, `WebSocketMultiplayerPeer` è nativo in Godot.

**`var_to_bytes` e non JSON** — entrambi i lati sono Godot 4.7, e `var_to_bytes` preserva `Vector2i`
nativamente. Con JSON, `ui/combat_view.gd:262` (`var cell: Vector2i = entry["cell"]`) esploderebbe e
servirebbe un layer di ri-tipizzazione a mano su tutto l'event log. Con `var_to_bytes` il problema
non esiste. È anche più compatto.

**`WebSocketMultiplayerPeer` usato come peer grezzo** (`poll()`, `get_packet()`,
`get_packet_peer()`, `set_target_peer()`), **non** con `SceneMultiplayer`/`@rpc`: il protocollo è un
comando esplicito da validare, non una chiamata remota di funzione. Con `@rpc` la validazione
diventa implicita e fragile.

---

## Architettura di destinazione

```
   App Android ──── https ────► Supabase (Frankfurt)
        │                        Auth (Google) + Postgres
        │
        │ wss://game.tuodominio.it
        ▼
   ┌──────────────────────────────────────────────┐
   │  Caddy :443  (TLS automatico, route STATICHE) │
   │    /ws/mm  → 127.0.0.1:9000   master          │
   │    /ws/w1  → 127.0.0.1:9001   worker 1        │
   │    /ws/w2  → 127.0.0.1:9002   worker 2  …     │
   └───────┬───────────────────────┬───────────────┘
           │                       │
   ┌───────▼─────────┐    ┌────────▼────────────────┐
   │ MASTER           │    │ WORKER (godot --headless)
   │ godot --headless │    │  N MatchRunner in parallelo
   │ - verifica JWT   │    │  ognuno possiede un MatchState
   │ - coda + timer   │───►│  - timer preparazione 30s
   │   30s            │    │  - valida OGNI comando
   │ - riempie a 8    │assegna- BotBrain per gli slot vuoti
   │   con bot        │lobby │  - resolve_round() + invio log
   │ - sceglie worker │    │  - scrive risultati su Supabase
   └──────────────────┘    └─────────────────────────┘
```

**Perché route statiche e non un processo per match:** Caddy non deve ricaricare la config a ogni
partita. Un pool fisso di worker su porte note scala aggiungendo una riga di config più un servizio
systemd, usa tutti i core, e il master fa solo least-loaded routing. **Si parte con 1 worker.**

---

## M0 — Serializzazione e determinismo (nessuna rete)

**Obiettivo:** dare a `core/` la capacità di trasformarsi in dati e tornare indietro, con filtro
delle viste per giocatore. Tutto testabile offline, subito. Nessuna dipendenza dalle altre milestone.

### File da modificare
`core/unit_instance.gd`, `core/player.gd`, `core/match_state.gd`, `tests/run_tests.gd`.

### Task

**1. `core/unit_instance.gd`**
```gdscript
func to_dict() -> Dictionary          # uid, id, star, cell (Vector2i), on_board (bool)
static func from_dict(d: Dictionary) -> UnitInstance
```

**2. `core/player.gd`** — serializzazione con filtro delle viste:
```gdscript
# viewer = true  -> è il giocatore che riceve: include shop, gold, xp, panchina
# viewer = false -> è un avversario: SOLO index, display_name, hero_id, hp, level,
#                   streak, last_round_won, eliminated, placement, e le unità SUL TAVOLO
func to_dict(viewer: bool) -> Dictionary
func apply_dict(d: Dictionary) -> void
```
> Con `viewer = false` le chiavi `shop`, `gold`, `xp` **non devono esistere nel dizionario** — non
> vanno messe a zero, vanno omesse. Il test di M0 verifica esattamente questo.

Aggiungere i comandi indirizzati per **uid** (oggi esiste solo `sell_by_uid`, `core/player.gd:223`).
Sono wrapper di tre righe: `unit_by_uid()` esiste già a `core/player.gd:111`.
```gdscript
func move_to_board_by_uid(uid: int, cell: Vector2i) -> bool
func move_to_bench_by_uid(uid: int, slot: int = -1) -> bool
```

**3. `core/match_state.gd`**
```gdscript
func to_dict(for_index: int) -> Dictionary   # phase, stage, round_index, seed_value,
                                             # players[] (filtrati con viewer = (i == for_index)),
                                             # pool: UnitPool.snapshot()   <-- esiste già, unit_pool.gd:87
func apply_dict(d: Dictionary) -> void
```

**4. uid globali.** `_next_uid` è per-player, quindi **le uid collidono tra giocatori**. Regola per
tutto il protocollo: ogni riferimento a un'unità sul filo è la coppia `(player_index, uid)`, mai
`uid` da solo.

**5. Nuovi test in `tests/run_tests.gd`** — aggiungere le funzioni alla lista in `_initialize()`,
seguendo il pattern esistente (`section(...)` + `check(...)`):

- `_test_serialization_roundtrip` — `MatchState` → `to_dict()` → `var_to_bytes` → `bytes_to_var` →
  `apply_dict()` su una istanza vuota, e lo stato ricostruito è identico all'originale campo per
  campo (hp, gold, livello, unità con uid/star/cella, snapshot del pool).
- `_test_view_filtering` — **test anti-cheat.** Il dict di un giocatore visto da un *altro*
  giocatore **non contiene** le chiavi `shop`, `gold`, `bench`. Asserire con
  `check(not d.has("shop"), ...)`.

### Criteri di accettazione
```sh
godot --headless --path . --import
godot --headless --path . --script res://tests/run_tests.gd
```
- I 59 test preesistenti sono ancora verdi.
- I 2 nuovi test passano.
- Il test di determinismo **non è stato modificato**.

---

## M1 — Supabase: progetto, schema, migrazioni

**Obiettivo:** avere il database in produzione con schema versionato nel repo, RLS attiva, e la
creazione automatica del profilo al primo login.

### Prerequisiti manuali (l'utente li fa a mano, una volta)
1. Creare il progetto Supabase in region **Frankfurt (eu-central-1)**.
2. Abilitare il provider **Google** in Authentication → Providers (serve un OAuth Client ID di
   Google Cloud Console, tipo "Web application").
3. Aggiungere `http://127.0.0.1` tra i **Redirect URLs** consentiti (serve a M2).
4. Installare la CLI: `npm i -g supabase`, poi `supabase login` e `supabase link --project-ref <ref>`.

### Nuova cartella, versionata nel repo
```
db/
  config.toml            # generato da: supabase init
  migrations/
    0001_initial.sql
  seed.sql               # dati di comodo per lo sviluppo locale
```

### `db/migrations/0001_initial.sql`

`auth.users` è gestita da Supabase; noi aggiungiamo solo lo schema `public`:

```sql
create table public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
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
  source      text not null,                  -- 'default' | 'purchase' | 'promo'
  acquired_at timestamptz not null default now(),
  primary key (profile_id, civ_id)
);

create table public.match_history (
  id         uuid primary key default gen_random_uuid(),
  seed       bigint not null,
  ranked     boolean not null default true,
  started_at timestamptz not null default now(),
  ended_at   timestamptz,
  results    jsonb not null                   -- [{profile_id, placement, hp, ...}]
);
```

**Trigger di primo login** — nessun endpoint di registrazione da scrivere:
```sql
create function public.handle_new_user() returns trigger
language plpgsql security definer as $$
begin
  insert into public.profiles (id, username)
    values (new.id, coalesce(new.raw_user_meta_data->>'name',
                             'player_' || left(new.id::text, 8)));
  insert into public.player_stats (profile_id) values (new.id);
  insert into public.owned_civs (profile_id, civ_id, source)
    values (new.id, 'roman', 'default'), (new.id, 'gaul', 'default');
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
```

**RLS — obbligatoria, non opzionale.** Senza, chiunque abbia la anon key (che è dentro l'APK) legge
tutto il database.
```sql
alter table public.profiles     enable row level security;
alter table public.player_stats enable row level security;
alter table public.owned_civs   enable row level security;
alter table public.match_history enable row level security;

create policy "own profile read"   on public.profiles     for select using (auth.uid() = id);
create policy "own profile update" on public.profiles     for update using (auth.uid() = id);
create policy "own stats read"     on public.player_stats for select using (auth.uid() = profile_id);
create policy "own civs read"      on public.owned_civs   for select using (auth.uid() = profile_id);
-- match_history: nessuna policy -> il client non legge nulla. Solo il server (service_role).
```
> **Nota:** non esiste alcuna policy di **scrittura** su `player_stats`, `owned_civs`,
> `match_history`. Le scrive solo il server con la `service_role` key, che bypassa la RLS. Il client
> non può toccare nulla che dia vantaggio competitivo.

**GDPR** — gli utenti sono italiani, quindi serve: privacy policy (obbligatoria anche per Play
Store) e cancellazione account. La cancellazione è `delete from auth.users where id = ...`; il
`on delete cascade` pulisce tutto il resto.

### Criteri di accettazione
```sh
supabase start      # Postgres + Auth locali in Docker; Studio su http://localhost:54323
supabase db reset   # riapplica tutte le migrazioni da zero, senza errori
supabase db push    # applica sul progetto Frankfurt
```
- Creando un utente di test dallo Studio, compaiono automaticamente una riga in `profiles`, una in
  `player_stats` e due in `owned_civs`.
- Interrogando `profiles` con la **anon key** senza JWT si ottengono **zero righe** (RLS attiva).

---

## M2 — Autenticazione Google nel client

**Obiettivo:** il giocatore si logga con Google dall'app; il refresh token sopravvive al riavvio; il
single-player continua a funzionare da sloggati e offline.

### Il vincolo che decide l'approccio

`export_presets.cfg` ha `gradle_build/use_gradle_build=false` e **nessun `.aar` è stato compilato** —
non c'è oggi un plugin Android nativo nel progetto, e Godot non ha Google Sign-In built-in.
Scrivere un plugin Kotlin sarebbe la strada lunga.

### Soluzione: OAuth nel browser con redirect su loopback

È il pattern raccomandato per le app native (RFC 8252). **Non richiede modifiche all'
AndroidManifest, né deep link, né gradle build.**

1. il client apre un `TCPServer` su `127.0.0.1:<porta libera>`
2. genera un PKCE `code_verifier` (random) e il `code_challenge` (SHA256 + base64url)
3. `OS.shell_open()` sull'URL di autorizzazione Supabase:
   `https://<ref>.supabase.co/auth/v1/authorize?provider=google&redirect_to=http://127.0.0.1:<porta>/callback&code_challenge=<c>&code_challenge_method=S256`
4. il browser di sistema fa il consenso Google; Supabase redirige sul loopback con `?code=...`
5. il `TCPServer` legge la request HTTP, estrae il `code`, risponde una paginetta
   *"Login completato, puoi tornare al gioco"*, e si chiude
6. il client scambia `code` + `code_verifier` per `access_token` (JWT) + `refresh_token` con una
   `HTTPRequest` POST su `/auth/v1/token?grant_type=pkce`

### Nuovi file

**`net/auth.gd`** — autoload `Auth`. **Modellarlo sulla facade `monetization/store.gd`**: è già il
pattern del progetto, con degradazione a no-op quando il backend non è disponibile
(`monetization/store.gd:38-46`).
```gdscript
signal login_completed(success: bool, reason: String)
signal logged_out

func is_logged_in() -> bool
func login_google() -> void          # avvia il flusso loopback+PKCE
func logout() -> void
func user_id() -> String             # il "sub" del JWT = uuid Supabase; "" se sloggato
func access_token() -> String        # "" se sloggato
func try_restore_session() -> void   # chiamato in _ready(): refresh token da user://auth.dat
```

**`net/supabase_client.gd`** — wrapper `HTTPRequest` su Auth REST + PostgREST. Legge URL e anon key
da `data/catalog.json` (dove già stanno le chiavi pubbliche) o da un nuovo `data/backend.json`.

> **Attenzione all'autoload:** `ui/menu.gd:43-45` prende gli autoload con
> `get_node("/root/Store")`, **mai per nome globale**, perché gli script compilati da riga di
> comando (i test headless) non risolvono i globali degli autoload. `Auth` va usato allo stesso modo.

### Persistenza

`user://auth.dat`, **separato** da `profile.cfg`. Contiene solo il refresh token. Al boot si prova
il refresh; se fallisce si resta ospiti e il single-player funziona comunque.

### `app/profile.gd` — sdoppiare la responsabilità senza rompere l'offline

| Campo | Destino |
|---|---|
| `combat_speed`, `seen_tips` | **restano locali** — sono preferenze di dispositivo |
| `favourite_origin`, `favourite_hero` | sincronizzati con `profiles` al login (pull all'avvio, push al cambio) |
| `matches_played`, `best_placement` | per le partite **online** li scrive **solo il server**; le partite offline aggiornano solo il contatore locale |

`monetization/store.gd:55` — `user_id()` passa dall'`OS.get_unique_id()` all'uid Supabase quando
loggato. È il seam già annotato nel codice: serve perché gli acquisti RevenueCat seguano l'account
tra dispositivi.

### Android

Verificare e aggiungere il permesso **INTERNET** in `export_presets.cfg`
(`permissions/custom_permissions` è oggi `PackedStringArray()` **vuoto**). Senza, la build di
release non fa una singola richiesta di rete e il bug è difficile da diagnosticare.

### Criteri di accettazione
- Nuovo `tests/auth_smoke.gd` sul modello frame-pump di `tests/menu_smoke.gd` (che usa
  `match _frames:` in `_process`, con frame di margine per i cambi scena): parte da sloggato,
  verifica che il menu si costruisca, che `Auth.is_logged_in()` sia `false` senza crash, e che il
  **single-player parta comunque**.
- Prova manuale su dispositivo: login Google, chiusura app, riapertura → ancora loggato.
- Modalità aereo → l'app si apre, resta ospite, e il single-player funziona.

---

## M3 — `MatchSession`: l'astrazione che tiene insieme offline e online

**Obiettivo:** disaccoppiare `ui/main.gd` dal `MatchState` locale, **senza cambiare un solo
comportamento**. È il refactor che evita di duplicare `ui/main.gd` in una versione online.

### Perché così

`ui/main.gd` oggi tiene `var match_state: MatchState` (`ui/main.gd:19`) e chiama direttamente 11
metodi mutanti. Si replica lo schema **interfaccia + backend** già usato in
`monetization/store_backend.gd`.

**Il trucco che rende il diff piccolo:** `RemoteSession` terrà comunque un `MatchState`/`Player`
reale, solo che non lo simula mai — lo **riempie dagli snapshot** del server via `apply_dict()`.
Perciò **tutte le letture di `ui/main.gd` restano invariate** (`p.gold`, `p.bench_units()`,
`p.unit_at_cell()`, `match_state.players`, `TraitResolver.summary()`, …). Cambiano **solo le 11
scritture**.

### Le 11 chiamate mutanti da convertire

| `ui/main.gd` | Chiamata attuale | Diventa |
|---|---|---|
| 1143 | `player().reroll()` | `_session.request_reroll()` |
| 1149 | `player().buy_xp()` | `_session.request_buy_xp()` |
| 1159 | `player().sell(selected)` | `_session.request_sell(uid)` |
| 1176 | `p.buy(slot)` | `_session.request_buy(slot)` |
| 1187 | `p.move_to_board(selected, cell)` | `_session.request_move_to_board(uid, cell)` |
| 1204 | `p.move_to_bench(selected, slot)` | `_session.request_move_to_bench(uid, slot)` |
| 996 | `match_state.resolve_round()` | `_session.request_ready()` |
| 981, 1092 | `match_state.start_round()` | evento `round_started` dalla sessione |
| 971 | `MatchState.new(seed, 1)` | `_session.begin()` |
| 972 | `human_player().hero_id = ...` | passato dentro `begin()` / al join |
| 994 | `brain.play_preparation(...)` | interno a `LocalSession`; in remoto sta sul server |

### Nuovi file in `net/`

**`match_session.gd`** — classe base (`RefCounted`), metodi virtuali che non fanno nulla, esattamente
come `monetization/store_backend.gd`:
```gdscript
signal state_changed
signal round_started(stage: int, round_index: int)
signal combat_ready(combat: Dictionary, team: int)
signal round_concluded(results: Array)
signal match_finished(standings: Array)
signal command_rejected(reason: String)
signal connection_lost(reason: String)

func begin() -> void
func state() -> MatchState
func local_index() -> int
func request_buy(slot: int) -> void
func request_sell(uid: int) -> void
func request_reroll() -> void
func request_buy_xp() -> void
func request_move_to_board(uid: int, cell: Vector2i) -> void
func request_move_to_bench(uid: int, slot: int) -> void
func request_ready() -> void
func leave() -> void
```

**`local_session.gd`** — possiede un vero `MatchState`, applica i comandi in locale, costruisce i
`BotBrain` (il codice si sposta qui da `ui/main.gd:973-977`, **albero RNG compreso**:
`SimRNG.new(seed ^ 0x5EED)` poi `fork(p.index)` — non cambiare quei valori o le partite con lo
stesso seed non si riprodurranno più) ed emette i segnali. **Comportamento identico a oggi.**

**`remote_session.gd`** — solo lo scheletro in questa milestone; si completa in M6.

### Modifiche a `ui/main.gd`
- sostituire le 11 scritture
- il refresh della UI si aggancia al segnale `state_changed` invece di essere chiamato a mano dopo
  ogni azione (oggi `_refresh()` a `ui/main.gd:1217`)
- `_pending_results` (`ui/main.gd:73`) già bufferizza i risultati non rivelati durante il replay:
  è esattamente il buffer che riempirà un payload di rete. Non toccarlo.

### Criteri di accettazione
```sh
godot --headless --path . --import
godot --headless --path . --script res://tests/run_tests.gd
godot --headless --path . --script res://tests/ui_smoke.gd -- --seed=4242
godot --headless --path . --script res://tests/menu_smoke.gd
```
**Tutti e 3 i suite devono passare senza aver modificato i test.** Se `ui_smoke` (37 test) passa
intatto, il refactor è a comportamento zero. Questo è il criterio: non modificare i test per farli
passare.

> `ui_smoke` **richiede un seed fisso** (`-- --seed=4242`): senza, ogni run compra unità diverse e
> il test fallisce a intermittenza.

---

## M4 — Protocollo e master server

**Obiettivo:** un giocatore loggato entra in coda, e dopo 30 s (o a 8 giocatori) riceve
l'assegnazione a una partita.

### Nuovi file

**`net/protocol.gd`** — condiviso client/server:
```gdscript
const PROTOCOL_VERSION := 1
const MAX_PACKET_BYTES := 262144       # rifiuta pacchetti più grandi, sempre

static func encode(msg: Dictionary) -> PackedByteArray   # var_to_bytes
static func decode(bytes: PackedByteArray) -> Dictionary # bytes_to_var, {} se malformato
```
Costanti dei tipi di messaggio (vedi la tabella in Appendice A).

**`server/master_server.gd`** — script `SceneTree`, avviato con:
```sh
godot --headless --path . --script res://server/master_server.gd -- --port=9000
```

**`server/matchmaker.gd`** — la coda.

### Flusso

1. il client si connette a `wss://…/ws/mm` e manda `HELLO {protocol_version, access_token}`
2. il master **verifica il JWT con la JWKS pubblica di Supabase**, scaricata all'avvio e cachata —
   non si chiama Supabase a ogni connessione. Estrae `sub` = uid.
   Se `protocol_version` non combacia → `REJECTED {reason: "version"}` e disconnessione; il client
   mostra "aggiorna il gioco".
3. il client manda `QUEUE_JOIN {hero_id}`. Il server **rilegge** `profiles` e `owned_civs` dal DB con
   la service_role key: **l'hero dichiarato dal client va validato, non creduto.**
4. all'ingresso del **primo** giocatore parte un `Timer` di **30 s**. Il master manda
   `QUEUE_UPDATE {players, seconds_left}` in broadcast ogni secondo.
5. a **8 giocatori** *oppure* allo **scadere del timer**: si sigilla la lobby, si generano gli slot
   mancanti come bot, si genera il `seed` (random, ma **sempre esplicito** — non affidarsi al
   default di `MatchState._init` che usa l'orologio di sistema, `core/match_state.gd:31`), si sceglie
   il worker meno carico e gli si manda `SPAWN_MATCH {match_id, seed, slots[]}` su un **canale di
   controllo interno** (socket su `127.0.0.1`, non esposto da Caddy).
6. il master risponde ai client `MATCH_ASSIGNED {match_id, worker_path, match_token}`. Il client
   chiude la connessione col master e ne apre una col worker.

`match_token` è un token a vita breve firmato dal master (HMAC con un segreto condiviso), così il
worker non deve rifare la verifica del JWT.

### Caso limite da gestire esplicitamente

Un solo giocatore in coda dopo 30 s → partita con **7 bot**. È il caso normale al lancio ed è
accettabile, ma va marcata `ranked = false` in `match_history` per non inquinare l'MMR.

### Criteri di accettazione
Nuovo `tests/net_smoke.gd`: avvia master e worker **in-process**, connette 3 client fittizi, e
verifica che allo scadere del timer parta una partita con 3 umani + 5 bot, e che tutti e 3 i client
ricevano lo **stesso** `match_id` e lo **stesso** `seed`.

---

## M5 — Worker: il match autoritativo

**Obiettivo:** il server possiede la partita, scandisce i round a tempo, valida ogni comando, e
manda a ciascuno solo ciò che gli spetta.

### Nuovi file

**`server/game_worker.gd`** — script `SceneTree`, un `WebSocketMultiplayerPeer` in ascolto e un
dizionario `match_id → MatchRunner`.

**`server/match_runner.gd`** — **il cuore.** Fa quello che oggi fa `ui/main.gd:986
_on_fight_pressed()`, ma con un timer al posto del bottone.

### Comportamento di `MatchRunner`

**Fase di preparazione.** `MatchState.preparation_seconds()` (`core/match_state.gd:67`) è **codice
morto oggi** — qui trova finalmente il suo chiamante. Restituisce 45 s al primo round e 30 s poi. Il
round si chiude allo **scadere del timer** *oppure* quando **tutti gli umani vivi** hanno mandato
`READY`.

**Intake comandi — validazione a tre livelli.** Ogni comando in arrivo passa da:

1. **Identità** — il peer corrisponde davvero a quel `player_index`?
2. **Fase** — siamo in `PREPARATION`? **Questo controllo non esiste in `core/`**: `Player` non sa
   nulla delle fasi e `core/player.gd` non lo verifica. Se non lo fa il server, un client può
   comprare durante il combattimento.
3. **Regole** — si delega ai metodi che **già esistono**: `can_buy()` (`core/player.gd:178`),
   `can_reroll()` (`core/player.gd:166`), e i valori di ritorno `bool`/`UnitInstance` degli altri
   mutanti. **Nessuna logica di gioco va duplicata nel server.**

Comando rifiutato → si risponde `COMMAND_REJECTED {reason}` e nient'altro. **Nessuna
disconnessione**: il client può essere semplicemente disallineato per un pacchetto in volo.

**Bot.** La costruzione dei `BotBrain` e il loro albero RNG vivono oggi in `ui/main.gd:973-977`: si
spostano qui (in M3 erano finiti in `LocalSession`; il server ne fa una copia).
`BotBrain.play_preparation(stage)` guida il player **solo tramite i metodi pubblici**, quindi
funziona lato server senza toccarlo.

> **Trappola:** il costruttore di `BotBrain` è a effetti collaterali — pesca l'origine preferita,
> **assegna `player.hero_id`**, e pesca l'`economy_floor`, tutto dallo stesso stream RNG, in
> quest'ordine. C'è un commento di avvertimento in `core/bot_brain.gd:25`. Non riordinare quelle
> pescate o si rompe la riproducibilità dei seed.

**Risoluzione.** `match_state.resolve_round()` — sincrono, restituisce già due dict per matchup, uno
per giocatore, ciascuno col `combat` completo dentro.

**Invio mirato.** A ogni giocatore va **solo il proprio** log di combattimento, non tutti e quattro.
Gli `events` sono illimitati (un `move` per unità per tick, più i `periodic` ogni 0.5 s —
`core/combat_sim.gd:258`): mandare 4 log completi a 8 giocatori a ogni round sarebbe uno spreco
enorme di banda mobile. Il log di un altro giocatore (spettatore) si manda **solo su richiesta
esplicita** (`SPECTATE_REQUEST`).

**Ritmo.** Dopo `resolve_round()` il server aspetta un tempo fisso (durata del combattimento più
lungo + margine) prima di aprire il round successivo, così chi guarda a ×1 non viene tagliato fuori.
Chi fa skip aspetta e basta.

**Disconnessione — fondamentale su mobile.** Il peer cade → il posto **non** viene eliminato: passa
a `BotBrain` e il `player_index` resta prenotato. Se il giocatore torna entro N round riprende il
suo posto, riconnettendosi col `match_token`. È la differenza tra un gioco mobile giocabile e uno
frustrante: su rete cellulare i socket cadono di continuo.

**Fine partita.** Il worker scrive `match_history` e aggiorna `player_stats` su Supabase con la
**service_role key**, in una transazione. Solo il server scrive quelle tabelle.

### Criteri di accettazione
Estendere `tests/net_smoke.gd`:
- un match completo con 1 client fittizio + 7 bot, pilotato fino alla fine; il client riceve
  `MATCH_FINISHED` con uno standing coerente (8 posizioni, nessun duplicato)
- un comando inviato **fuori fase** riceve `COMMAND_REJECTED` e **non altera lo stato**
- un comando che dichiara un `player_index` **non suo** viene rifiutato
- una disconnessione simulata a metà partita non elimina il giocatore, e la riconnessione col
  `match_token` restituisce il posto

---

## M6 — Client online: lobby e aggancio al menu

**Obiettivo:** chiudere il cerchio — dal menu alla partita online.

### Nuovi file
`ui/lobby.gd` + `ui/lobby.tscn`.

> **Convenzione del progetto:** i `.tscn` sono stub di 12 righe (un `Control` con lo script
> attaccato) e **tutta la UI si costruisce in codice** in `_build()`. Vedi `ui/menu.tscn` +
> `ui/menu.gd:104`. Seguire lo stesso schema, e usare `Style.apply_plate(...)` per restare coerenti
> con l'aspetto esistente.

### Modifiche

**`ui/menu.gd:930`** — il ramo `MODE_PVP` oggi apre un `AcceptDialog` "In arrivo". Diventa:
- se non loggato → `Auth.login_google()`, e al `login_completed(true, _)` si prosegue
- se loggato → `get_tree().change_scene_to_file("res://ui/lobby.tscn")`

**`ui/lobby.gd`** — si connette al master, manda `QUEUE_JOIN`, mostra "giocatori in coda: N/8" e il
countdown dei 30 s, permette di annullare, e al `MATCH_ASSIGNED` passa a `main.tscn` con una
`RemoteSession` già connessa al worker.

**`ui/main.gd`, modalità remota:**
- il bottone COMBATTI si nasconde; al suo posto il **timer di preparazione** e un bottone **PRONTO**
- il tasto Menu (`ui/main.gd:1113`, oggi `change_scene_to_file`) diventa **abbandona/arrenditi** con
  conferma: online non si può semplicemente distruggere la scena e sparire
- gestire `connection_lost` con un pannello di riconnessione, non con un crash

**`net/remote_session.gd`** — si completa: manda i comandi, riceve gli snapshot e li applica con
`MatchState.apply_dict()`, inoltra i log a `ui/combat_view.gd` (che è già completamente disaccoppiato
da `CombatSim`: legge solo un `Dictionary` — vedi `ui/combat_view.gd:236 load_combat()`).

### Attenzione al test esistente
`tests/menu_smoke.gd:71` fissa a **2** il numero di `_mode_option_buttons`. Non aggiungiamo un terzo
modo (restano CPU e PVP), ma il test va riletto perché il ramo PVP ora **cambia scena** invece di
aprire un dialog — e i cambi scena in quel test richiedono frame di margine (vedi il `match _frames:`
in `tests/menu_smoke.gd:25-51`).

### Criteri di accettazione
- `menu_smoke.gd` aggiornato e verde
- prova manuale su **due** dispositivi/emulatori reali: entrambi in coda, partita che parte a 30 s
  con 2 umani + 6 bot, combattimento **identico** sui due schermi

---

## M7 — Deploy

**Obiettivo:** il tutto gira sul VPS, con TLS, riavvio automatico e backup.

### Build del server
Aggiungere a `export_presets.cfg` un preset **Linux/X11 con `dedicated_server=true`** (oggi esiste
**solo** il preset Android, `[preset.0]`). In alternativa, per iniziare: copiare il progetto sul VPS
ed eseguirlo da sorgente con `--headless` — più veloce da iterare.

### VPS Hetzner
CPX21 basta per partire (~8 €/mese); si sale a CPX41 quando serve.

- **Caddy** — TLS automatico, route **statiche** per master e worker:
  ```
  game.tuodominio.it {
      reverse_proxy /ws/mm  127.0.0.1:9000
      reverse_proxy /ws/w1  127.0.0.1:9001
  }
  ```
- **systemd**: `autochess-master.service` e `autochess-worker@.service` (unit **template**, così
  aggiungere il worker 2 è `systemctl enable --now autochess-worker@2`)
- **secret** in `/etc/autochess/env`, mode `0600`: `SUPABASE_URL`,
  `SUPABASE_SERVICE_ROLE_KEY`, `MATCH_TOKEN_SECRET`.
  **La service_role key non deve mai finire nell'APK.**
- **ufw**: aperte solo 22 e 443. Le porte 9000+ restano in ascolto su `127.0.0.1`.
- **backup**: cron `pg_dump` notturno verso una Hetzner Storage Box (~3 €/mese), **indipendente** dai
  backup di Supabase.

### Nota su Supabase
Il free tier **mette in pausa il progetto dopo ~1 settimana di inattività** e non ha Point-in-Time
Recovery. Per un gioco pubblico serve il **piano Pro (~25 $/mese)**.

**Costo indicativo a regime iniziale: ~35-40 €/mese** (VPS + Supabase Pro + storage backup).

### Criteri di accettazione
- `systemctl status` verde per master e worker dopo un reboot del VPS
- un client Android su rete mobile (non Wi-Fi) completa una partita
- `pg_dump` notturno produce un file ripristinabile — **provare davvero il restore**, non solo che il
  file esista

---

## Appendice A — Protocollo

Ogni messaggio è un `Dictionary` con la chiave `t` (tipo). Codifica `var_to_bytes`.

### Client → Master
| `t` | Payload | Note |
|---|---|---|
| `HELLO` | `protocol_version, access_token` | primo messaggio, obbligatorio |
| `QUEUE_JOIN` | `hero_id` | l'hero va **rivalidato** contro il DB |
| `QUEUE_LEAVE` | — | |

### Master → Client
| `t` | Payload |
|---|---|
| `WELCOME` | `user_id, username, stats` |
| `REJECTED` | `reason` (`version` \| `auth` \| `banned`) |
| `QUEUE_UPDATE` | `players, seconds_left` |
| `MATCH_ASSIGNED` | `match_id, worker_path, match_token` |

### Client → Worker
| `t` | Payload |
|---|---|
| `JOIN` | `match_id, match_token` |
| `CMD_BUY` | `slot` |
| `CMD_SELL` | `uid` |
| `CMD_REROLL` | — |
| `CMD_BUY_XP` | — |
| `CMD_MOVE_BOARD` | `uid, cell` (`Vector2i`) |
| `CMD_MOVE_BENCH` | `uid, slot` |
| `READY` | — |
| `SPECTATE_REQUEST` | `player_index` |
| `SURRENDER` | — |

### Worker → Client
| `t` | Payload | Note |
|---|---|---|
| `MATCH_STATE` | `MatchState.to_dict(for_index)` | snapshot completo, filtrato |
| `ROUND_STARTED` | `stage, round_index, prep_seconds` | |
| `COMBAT` | `combat` (dict di `CombatSim.result()`), `team`, `opponent_hero_id` | **solo il proprio** |
| `ROUND_CONCLUDED` | `results[]` (senza i log altrui) | |
| `COMMAND_REJECTED` | `reason` | non disconnette |
| `MATCH_FINISHED` | `standings[]` | |
| `SPECTATE_DATA` | `combat`, `player_index`, `team`, `opponent_hero_id` | su richiesta; stesse regole zstd di `COMBAT` |

**Regole trasversali**
- pacchetti oltre `MAX_PACKET_BYTES` → scartati, connessione chiusa
- messaggio malformato (`decode` restituisce `{}`) → ignorato, mai un crash
- ogni `MATCH_STATE` è filtrato con `to_dict(for_index)`: **mai** mandare lo stato privato altrui
- `combat.events` illimitati: se un log supera ~200 KB, comprimerlo con
  `FileAccess.COMPRESSION_ZSTD` prima di spedirlo
- `SPAWN_MATCH` (canale interno master→worker, stessa porta dei client) porta un
  campo `spawn_sig` = HMAC-SHA256 dei suoi campi con `MATCH_TOKEN_SECRET`; il
  worker scarta quelli con firma assente o errata (`MatchToken.verify_control`)

---

## Appendice B — Riepilogo dei file

**Nuovi**
```
net/protocol.gd            net/auth.gd             net/supabase_client.gd
net/match_session.gd       net/local_session.gd    net/remote_session.gd
server/master_server.gd    server/matchmaker.gd
server/game_worker.gd      server/match_runner.gd
ui/lobby.gd  +  ui/lobby.tscn
db/config.toml  +  db/migrations/0001_initial.sql  +  db/seed.sql
tests/net_smoke.gd         tests/auth_smoke.gd
deploy/Caddyfile           deploy/*.service        deploy/README.md
```

**Modificati**
```
core/unit_instance.gd     to_dict / from_dict
core/player.gd            to_dict(viewer) / apply_dict, move_to_*_by_uid
core/match_state.gd       to_dict(for_index) / apply_dict
app/profile.gd            split locale/remoto, sync Supabase
ui/main.gd                le 11 scritture -> session.request_*, modalità remota
ui/menu.gd:930            ramo PVP -> login o lobby
monetization/store.gd:55  user_id() -> uid Supabase
project.godot             autoload Auth
export_presets.cfg        permesso INTERNET + preset server Linux
tests/run_tests.gd        test serializzazione + filtro viste
tests/menu_smoke.gd       ramo PVP aggiornato
CLAUDE.md                 documentare net/, server/, db/ e i nuovi comandi
```

**`core/` non cambia in logica di gioco:** guadagna solo serializzazione e wrapper per-uid.

---

## Appendice C — Rischi noti e trappole

| Rischio | Mitigazione |
|---|---|
| **Determinismo dei float cross-platform** — lo stato di combattimento è `float` (hp, cooldown, `time`) | Mitigato per costruzione: il client **non risimula mai**, riceve `initial` + `events`. **Non introdurre predizione del combattimento lato client.** |
| **Peso degli event log** — `combat_sim.gd` logga un `move` per unità per tick | Misurarli presto. Oltre ~200 KB, comprimere con ZSTD. Mandare a ciascuno solo il proprio log |
| **`GameData` è statico di processo** — tutte le partite di un worker condividono la stessa versione di `data/` | Non chiamare `GameData.reload()` con partite vive. Per aggiornare il bilanciamento: drenare il worker e riavviarlo |
| **uid non globali** — `_next_uid` è per-player, le uid collidono tra giocatori | Sul filo, ogni riferimento è `(player_index, uid)` |
| **`Player` non conosce le fasi** — non rifiuta nulla in base a `PREPARATION`/`COMBAT` | Il gate di fase lo fa il server in `match_runner.gd`, livello 2 della validazione |
| ~~**Rematch ripetuti** — `build_matchups()` non ha memoria degli avversari passati~~ | **Risolto (A7):** `_recent_opponents` + scelta greedy che evita gli ultimi `REMATCH_AVOID_WINDOW` round |
| **Autoload non risolvibili da riga di comando** | Usare `get_node("/root/Auth")`, mai il nome globale — vedi `ui/menu.gd:43-45` |
| **`PackedStringArray` non è copy-on-write** | Quando si duplica `seen_tips` in un test, sempre `.duplicate()`; l'assegnazione diretta condivide il buffer |
| **Cache delle classi stantia** | Dopo ogni nuovo `class_name`, eseguire `godot --headless --path . --import` **prima** dei test, o il parser non trova la classe |

---

## Appendice D — Comandi di verifica

```sh
# Godot non è nel PATH:
# C:\Users\afalc\Downloads\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe

godot --headless --path . --import                                          # dopo ogni nuovo class_name
godot --headless --path . --script res://tests/run_tests.gd                 # engine (59 test + i nuovi)
godot --headless --path . --script res://tests/ui_smoke.gd -- --seed=4242   # match completo (37 test)
godot --headless --path . --script res://tests/menu_smoke.gd                # menu (19 test)
godot --headless --path . --script res://tests/net_smoke.gd                 # rete (nuovo)
godot --headless --path . --script res://tests/auth_smoke.gd                # auth (nuovo)

# Server, in locale
godot --headless --path . --script res://server/master_server.gd -- --port=9000
godot --headless --path . --script res://server/game_worker.gd  -- --port=9001

# Database
supabase start ; supabase db reset ; supabase db push
```

Tutti gli script di test escono con codice 1 in caso di fallimento.

**Prova finale end-to-end:** due dispositivi Android reali, login Google su entrambi, entrambi in
coda, partita che parte a 30 s con 2 umani + 6 bot, combattimento identico sui due schermi,
statistiche aggiornate su Supabase a fine partita, e un test di riconnessione (modalità aereo
on/off a metà partita).
