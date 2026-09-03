# LOGIN_PLAN.md — login obbligatorio all'avvio + account email/password

Piano esecutivo. Ogni sezione è un passo autosufficiente: file da toccare, cosa scrivere, come
verificarlo. Seguire l'ordine (il DB prima, la UI per ultima).

---

## 0. Contesto e decisioni

Oggi l'identità è **solo Google** e il login è **implicito e tardivo**: `ui/menu.tscn` è la scena
principale e `ui/menu.gd::_start_pvp()` chiama `Auth.login_google()` solo quando si preme BATTAGLIA
in modalità PVP. Non esiste una schermata di login, non esistono account email/password, e
`profiles.google_sub` è `not null` (`db/migrations/0001_initial.sql:29`): il database non può
nemmeno rappresentare un account senza Google.

Obiettivo: si arriva alla home **dopo** essersi identificati, con tre vie (Google, email/password,
ospite); chi ha un token valido non rivede mai la schermata.

Decisioni prese con l'utente, da non rimettere in discussione:

| Scelta | Decisione |
|---|---|
| Ospite | **Terza opzione** sulla schermata di login: gioco offline vs bot, niente multiplayer né statistiche |
| Scope email/password | **Solo registrazione + login**. Niente verifica email, niente recupero password, zero SMTP |
| Durata sessione | **90 giorni** (`REFRESH_TTL_DAYS` da 7 a 90) |

Il pezzo di architettura che rende il lavoro contenuto: `AccountService._issue_session()`
(`server/account_service.gd:44`) è già il collo di bottiglia comune a Google e refresh — prende una
`row` nella forma prodotta da `_account_bundle` e ne fa il bundle `AUTH_OK`. Una nuova RPC SQL che
restituisce **la stessa forma** riusa tutto il resto senza modifiche.

Invariante da non rompere, garantita da `tests/auth_smoke.gd`: **il gioco offline funziona senza
account**. Con `data/backend.json` sui segnaposto (cioè nei test headless) la schermata di login non
deve nemmeno comparire.

---

## 1. `db/migrations/0003_email_password.sql` (nuovo)

Le migrazioni già applicate non si toccano mai: `db/apply.sh` tiene `public.schema_migrations` per
nome file e salta quelle registrate.

**Prima di applicare**, verificare che l'indice unico sull'email non trovi duplicati:

```sql
select lower(email), count(*) from public.profiles
 where email is not null group by 1 having count(*) > 1;
```

Contenuto del file:

```sql
-- =============================================================================
-- 0003_email_password.sql — account con email e password accanto a Google
-- =============================================================================
--
-- Fino a 0001 l'identita' era solo Google (profiles.google_sub not null). Qui
-- google_sub diventa nullable e compare password_hash: un profilo puo' esistere
-- con l'uno, con l'altro, mai con nessuno dei due (vincolo in fondo).
--
-- Le password sono hashate con bcrypt di pgcrypto (crypt + gen_salt('bf', 10)),
-- gia' installata in 0001 per gen_random_uuid(). Il confronto avviene DENTRO al
-- database: la password in chiaro non esce mai da qui e non viene mai loggata.
-- =============================================================================

alter table public.profiles alter column google_sub drop not null;
alter table public.profiles add column password_hash text;

-- Un account per email. Parziale perche' un profilo Google puo' non avere email.
-- Postgres ammette piu' NULL in un indice unico, quindi gli account email non
-- collidono fra loro su google_sub rimasto nullo.
create unique index profiles_email_lower_idx
  on public.profiles (lower(email)) where email is not null;

-- Un profilo deve avere almeno un modo per autenticarsi.
alter table public.profiles add constraint profiles_has_credential
  check (google_sub is not null or password_hash is not null);


-- -----------------------------------------------------------------------------
-- register_email_account — creazione account con email e password.
-- Ritorna il bundle di _account_bundle, oppure {"error": "..."} se rifiutata.
-- Idempotente non lo e' e non deve esserlo: la seconda registrazione con la
-- stessa email e' un errore, non un login.
-- -----------------------------------------------------------------------------
create function public.register_email_account(
  p_email    text,
  p_password text,
  p_username text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email  text := lower(trim(p_email));
  v_id     uuid;
  v_base   text;
  v_final  text;
  v_suffix int := 0;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
     or length(p_password) < 8 then
    return jsonb_build_object('error', 'invalid');
  end if;

  if exists (select 1 from public.profiles where lower(email) = v_email) then
    return jsonb_build_object('error', 'email_taken');
  end if;

  -- username e' unique: si de-duplica invece di far fallire la registrazione.
  -- Stessa logica di upsert_google_account (0001).
  v_base := coalesce(nullif(trim(p_username), ''), 'player_' || left(md5(v_email), 8));
  v_final := v_base;
  while exists (select 1 from public.profiles where username = v_final) loop
    v_suffix := v_suffix + 1;
    v_final := v_base || '_' || v_suffix::text;
  end loop;

  insert into public.profiles (email, username, password_hash)
    values (v_email, v_final, crypt(p_password, gen_salt('bf', 10)))
    returning id into v_id;
  insert into public.player_stats (profile_id) values (v_id);
  insert into public.owned_civs (profile_id, civ_id, source)
    values (v_id, 'roman', 'default'), (v_id, 'gaul', 'default');

  return public._account_bundle(v_id);
end $$;


-- -----------------------------------------------------------------------------
-- login_email_account — verifica le credenziali, ritorna il bundle o null.
--
-- null copre indistintamente "email inesistente" e "password sbagliata": dire
-- quale delle due e' l'enumerazione degli account registrati.
-- -----------------------------------------------------------------------------
create function public.login_email_account(
  p_email    text,
  p_password text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  select id into v_id from public.profiles
   where lower(email) = lower(trim(p_email))
     and password_hash is not null
     and password_hash = crypt(p_password, password_hash);
  if v_id is null then
    return null;
  end if;
  return public._account_bundle(v_id);
end $$;


-- -----------------------------------------------------------------------------
-- Grant (stesso schema di 0001: autochess_app e' il ruolo di master e worker).
-- -----------------------------------------------------------------------------
grant insert on public.profiles to autochess_app;
grant execute on function public.register_email_account(text, text, text) to autochess_app;
grant execute on function public.login_email_account(text, text)          to autochess_app;
```

**Verifica** (Postgres locale di `db/docker-compose.dev.yml`):

```sh
./db/apply.sh "postgres://postgres:postgres@127.0.0.1:5432/postgres"
psql "$DB_URL" -c "select public.register_email_account('a@b.it','password1','Tizio')"   -- bundle
psql "$DB_URL" -c "select public.register_email_account('a@b.it','password1','Tizio')"   -- {"error":"email_taken"}
psql "$DB_URL" -c "select public.register_email_account('nonvale','password1','X')"      -- {"error":"invalid"}
psql "$DB_URL" -c "select public.login_email_account('a@b.it','password1')"              -- bundle
psql "$DB_URL" -c "select public.login_email_account('a@b.it','sbagliata')"              -- null
```

---

## 2. `net/protocol.gd`

Accanto agli altri `AUTH_*` (blocco "Client -> Master (autenticazione, prima di HELLO)"):

```gdscript
const AUTH_EMAIL_LOGIN  := "AUTH_EMAIL_LOGIN"   # {email, password}
const AUTH_EMAIL_SIGNUP := "AUTH_EMAIL_SIGNUP"  # {email, password, username}
```

Le risposte restano `AUTH_OK` / `AUTH_FAIL {reason}`. Nuove `reason` in circolazione:
`email_taken`, `invalid_credentials`, `invalid`, `rate_limited`.

Portare `PROTOCOL_VERSION` da 2 a **3**: client e server si rilasciano insieme e un client vecchio
non ha il gate di login, quindi è giusto che venga respinto in HELLO con `REJECTED {version}`.

---

## 3. `server/db_client.gd`

Due wrapper modellati riga per riga su `upsert_google_account`:

```gdscript
const RPC_REGISTER_EMAIL := "/rpc/register_email_account"
const RPC_LOGIN_EMAIL := "/rpc/login_email_account"


## register_email_account(p_email, p_password, p_username) -> bundle, oppure
## {"error": "email_taken"|"invalid"}. cb.call(ok: bool, row: Dictionary)
static func register_email_account(owner: Node, email: String, password: String,
		username: String, cb: Callable) -> void:
	var body := JSON.stringify({"p_email": email, "p_password": password, "p_username": username})
	_rpc(owner, RPC_REGISTER_EMAIL, body, func(ok: bool, data: Variant) -> void:
		cb.call(ok and data is Dictionary, data if data is Dictionary else {}))


## login_email_account(p_email, p_password) -> bundle, oppure null se le
## credenziali non tornano. cb.call(ok: bool, row: Dictionary); ok=false anche
## quando la password e' sbagliata (la RPC ritorna null, che non e' un Dictionary).
static func login_email_account(owner: Node, email: String, password: String, cb: Callable) -> void:
	var body := JSON.stringify({"p_email": email, "p_password": password})
	_rpc(owner, RPC_LOGIN_EMAIL, body, func(ok: bool, data: Variant) -> void:
		cb.call(ok and data is Dictionary, data if data is Dictionary else {}))
```

Non aggiungere niente al `push_warning` di `_request`: l'URL è già l'unica cosa che stampa, e il
body con la password non deve finire nei log.

---

## 4. `server/account_service.gd`

`REFRESH_TTL_DAYS := 90` (era 7). Poi due funzioni che confluiscono entrambe in `_issue_session`,
che resta **invariata**:

```gdscript
const MIN_PASSWORD_LEN := 8


## cb.call(ok: bool, bundle: Dictionary) — stessa forma di login_google.
static func login_email(owner: Node, email: String, password: String, cb: Callable) -> void:
	if not _credentials_plausible(email, password):
		cb.call(false, {"reason": "invalid"})
		return
	DbClient.login_email_account(owner, email, password, func(ok: bool, row: Dictionary) -> void:
		if not ok:
			cb.call(false, {"reason": "invalid_credentials"})
			return
		_issue_session(owner, row, cb))


static func register_email(owner: Node, email: String, password: String,
		username: String, cb: Callable) -> void:
	if not _credentials_plausible(email, password):
		cb.call(false, {"reason": "invalid"})
		return
	DbClient.register_email_account(owner, email, password, username, func(ok: bool, row: Dictionary) -> void:
		if not ok:
			cb.call(false, {"reason": "db"})
			return
		# La RPC segnala il rifiuto nel corpo, non con un codice HTTP.
		if row.has("error"):
			cb.call(false, {"reason": String(row["error"])})
			return
		_issue_session(owner, row, cb))


## Il client non e' autorevole: le stesse regole valgono anche qui, prima di
## spendere un giro di rete verso il database.
static func _credentials_plausible(email: String, password: String) -> bool:
	if password.length() < MIN_PASSWORD_LEN:
		return false
	var at := email.find("@")
	return at > 0 and email.find(".", at) > at + 1 and not email.contains(" ")
```

---

## 5. `server/master_server.gd`

**5a. Instradamento.** Aggiungere i due tipi all'intercettazione pre-matchmaker nel ciclo dei
pacchetti (dove oggi si testano `AUTH_GOOGLE`/`AUTH_REFRESH`/`PROFILE_SET`/`DELETE_ACCOUNT`):

```gdscript
		if pt == Protocol.AUTH_GOOGLE or pt == Protocol.AUTH_REFRESH \
				or pt == Protocol.AUTH_EMAIL_LOGIN or pt == Protocol.AUTH_EMAIL_SIGNUP \
				or pt == Protocol.PROFILE_SET or pt == Protocol.DELETE_ACCOUNT:
```

**5b. Due arm in `_handle_auth`**, con il rate limiting davanti:

```gdscript
		Protocol.AUTH_EMAIL_LOGIN:
			var email := String(msg.get("email", ""))
			if _rate_limited(email):
				_reply(peer_id, Protocol.make(Protocol.AUTH_FAIL, {"reason": "rate_limited"}))
				return
			AccountService.login_email(_pump, email, String(msg.get("password", "")),
				func(ok: bool, bundle: Dictionary) -> void:
					_note_attempt(email, ok)
					_reply_auth(peer_id, ok, bundle))
		Protocol.AUTH_EMAIL_SIGNUP:
			AccountService.register_email(_pump,
				String(msg.get("email", "")),
				String(msg.get("password", "")),
				String(msg.get("username", "")),
				func(ok: bool, bundle: Dictionary) -> void: _reply_auth(peer_id, ok, bundle))
```

**5c. Rate limiting.** `net/auth.gd` apre una WebSocket nuova a ogni richiesta, quindi contare per
peer non protegge da niente: la chiave è l'email.

```gdscript
## Tentativi di login falliti per email. Serve a rendere inutile provare le
## password a raffica: la chiave e' l'email e non il peer perche' il client apre
## una connessione nuova a ogni richiesta.
const LOGIN_MAX_FAILS := 8
const LOGIN_WINDOW := 300.0

var _login_fails: Dictionary = {}     # email_lower -> {count: int, first: float}


func _rate_limited(email: String) -> bool:
	var key := email.to_lower().strip_edges()
	var entry: Dictionary = _login_fails.get(key, {})
	if entry.is_empty():
		return false
	if _now() - float(entry["first"]) > LOGIN_WINDOW:
		_login_fails.erase(key)
		return false
	return int(entry["count"]) >= LOGIN_MAX_FAILS


func _note_attempt(email: String, ok: bool) -> void:
	var key := email.to_lower().strip_edges()
	if ok:
		_login_fails.erase(key)
		return
	var entry: Dictionary = _login_fails.get(key, {"count": 0, "first": _now()})
	if _now() - float(entry["first"]) > LOGIN_WINDOW:
		entry = {"count": 0, "first": _now()}
	entry["count"] = int(entry["count"]) + 1
	_login_fails[key] = entry
```

Purgare le voci scadute nello stesso punto in cui il master fa già la manutenzione periodica delle
partite sigillate (`_sealed_mms`), così il dizionario non cresce senza limite. `_now()` va preso
dalla stessa fonte già usata nel file per gli altri timer.

**Mai loggare la password**: non aggiungerla a `print`/`push_warning` in nessun ramo, nemmeno in
debug temporaneo.

---

## 6. `net/auth.gd` (client)

Tutto passa dalla macchina a richieste one-shot esistente (`_master_request`).

**6a. Comandi nuovi**, modellati su `try_restore_session()`:

```gdscript
## Login con email e password. Emette login_completed(success, reason) come
## login_google(): la UI non deve distinguere il provider.
func login_email(email: String, password: String) -> void:
	if not is_configured():
		login_completed.emit(false, "backend non configurato")
		return
	_login_source = "login"
	_master_request(
		Protocol.make(Protocol.AUTH_EMAIL_LOGIN, {"email": email, "password": password}),
		[Protocol.AUTH_OK, Protocol.AUTH_FAIL],
		_on_auth_reply.bind("login"))


func register_email(email: String, password: String, username: String) -> void:
	if not is_configured():
		login_completed.emit(false, "backend non configurato")
		return
	_login_source = "login"
	_master_request(
		Protocol.make(Protocol.AUTH_EMAIL_SIGNUP,
			{"email": email, "password": password, "username": username}),
		[Protocol.AUTH_OK, Protocol.AUTH_FAIL],
		_on_auth_reply.bind("login"))
```

Il resto del percorso (`_apply_bundle`, `_save_refresh_token`) è già a posto e non va toccato.

**6b. Stato del ripristino.** Oggi `try_restore_session()` fallisce in silenzio e la UI non ha modo
di sapere quando ha finito — che è esattamente ciò che serve al gate d'avvio.

```gdscript
## Emesso quando try_restore_session() ha finito, in entrambi gli esiti. La
## schermata di login lo aspetta prima di decidere se mostrarsi.
signal session_restore_finished(success: bool)

var _restoring: bool = false

func restore_pending() -> bool:
	return _restoring
```

- `try_restore_session()`: impostare `_restoring = true` subito prima di `_master_request(...)` (non
  prima dei controlli: se non c'è il file o il backend non è configurato il flag non si alza mai e
  `restore_pending()` è falso da subito).
- `_on_auth_reply`: nel ramo di successo e nel ramo `source == "restore"` fallito, se `_restoring`
  era vero azzerarlo ed emettere `session_restore_finished(ok)`.
- Anche il fallimento di trasporto (`_finish_ws(false, {})`) passa da `_on_auth_reply`, quindi è
  coperto: il segnale arriva **sempre**, al più tardi allo scadere dei 20 s di `_ws_deadline`.

**6c. Ospite.** La scelta va ricordata, altrimenti chi gioca offline rivede la schermata a ogni
avvio.

```gdscript
## Modalita' ospite: si gioca offline contro i bot, niente multiplayer ne'
## statistiche. La scelta si ricorda in Profile, altrimenti la schermata di
## login tornerebbe a ogni avvio a chi ha gia' detto di no.
func continue_as_guest() -> void:
	var profile := get_node_or_null("/root/Profile")
	if profile != null:
		profile.set_guest_mode(true)


func is_guest() -> bool:
	var profile := get_node_or_null("/root/Profile")
	return profile != null and profile.guest_mode
```

In `logout()`, oltre a quello che già fa, azzerare il flag ospite (`set_guest_mode(false)`): serve a
far ricomparire la schermata di login quando si esce dall'account.

**6d. Helper di validazione statici**, condivisi da UI e test invece di riscrivere la regex:

```gdscript
static func email_looks_valid(email: String) -> bool:
	var e := email.strip_edges()
	var at := e.find("@")
	return at > 0 and e.find(".", at) > at + 1 and not e.contains(" ") and not e.ends_with(".")


## "" se la password va bene, altrimenti il messaggio da mostrare.
static func password_problem(password: String) -> String:
	if password.length() < 8:
		return "La password deve avere almeno 8 caratteri."
	return ""
```

`user://auth.dat` **non cambia formato** (refresh token in chiaro, una riga): gli installati
esistenti continuano a funzionare. La durata reale la decide il server con `REFRESH_TTL_DAYS = 90`.

---

## 7. `app/profile.gd`

Aggiungere il campo che regge la scelta ospite, con lo stesso schema di tutti gli altri:

```gdscript
## Chi ha scelto "gioca come ospite" non deve rivedere la schermata di login a
## ogni avvio. Si azzera al logout, che e' l'unico modo per tornarci.
var guest_mode: bool = false

func set_guest_mode(value: bool) -> void:
	guest_mode = value
	save_profile()
	changed.emit()
```

E la coppia di righe corrispondenti in `load_profile()` / `save_profile()`, sezione `preferences`:
`config.get_value("preferences", "guest_mode", false)` e il `set_value` gemello. **Non dimenticare
la riga in `save_profile()`**: quel metodo ricostruisce un `ConfigFile` da zero, quindi una chiave
non scritta viene persa silenziosamente al primo salvataggio.

---

## 8. `ui/castle_backdrop.gd` (nuovo) — sfondo condiviso

Il requisito "stesso sfondo della home" si soddisfa **estraendo** il disegno, non duplicandolo.
Oggi la facciata sta dentro `ui/menu.gd`: le costanti `COLUMN_W`, `FACADE_TOP`, `SPRING_Y`,
`FLOOR_H` e i metodi `_castle_backdrop`, `_draw_castle`, `_draw_merlons`, `_draw_facade`,
`_draw_columns`, `_draw_arch`, `_draw_floor`, `_draw_torches`.

Spostarli **così come sono** (commenti inclusi: spiegano perché le costanti non sono frazioni dello
schermo) in:

```gdscript
class_name CastleBackdrop
extends Control

## Ingresso di un castello disegnato a runtime: due colonne di pietra a tutta
## altezza sui bordi e un arco a incorniciare il titolo. Zero asset su disco.
##
## Sta qui e non piu' dentro menu.gd perche' lo condividono la home e la
## schermata di login: sono la stessa stanza, e il giocatore deve vedere che
## l'accesso avviene gia' dentro al gioco.
##
## Le costanti sono pubbliche: chi lo usa ne ricava i margini del proprio
## contenuto, cosi' niente finisce mai sopra alla pietra.
```

- `_init()` (o `_ready()`) fa quello che faceva `_castle_backdrop()`:
  `set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)`,
  `mouse_filter = MOUSE_FILTER_IGNORE`, `draw.connect(...)`, `resized.connect(queue_redraw)`.
- I `_draw_*` diventano metodi della classe e disegnano su `self` invece che sul `canvas` passato.

In `ui/menu.gd::_build()`:

```gdscript
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))
	add_child(CastleBackdrop.new())
```

e i margini del `MarginContainer` leggono `CastleBackdrop.COLUMN_W`, `.SPRING_Y`, `.FLOOR_H`.
Rimuovere da `menu.gd` le costanti e i metodi spostati. **Nessun cambiamento visivo alla home**: è
un puro spostamento di codice, e lo screenshot di verifica deve risultare identico a prima.

> Dopo aver aggiunto un `class_name` serve un import una tantum, altrimenti la cache delle classi è
> stale e il parser non lo trova: `godot --headless --path . --import`.

---

## 9. `ui/login.gd` + `ui/login.tscn` (nuovi)

`login.tscn` è uno **stub**, come `ui/menu.tscn` e `ui/lobby.tscn`: un `Control` con
`anchors_preset = 15` e lo script attaccato. Tutta la UI si costruisce in `_build()`.

**9a. Scorciatoie in `_ready()`, prima di costruire qualsiasi cosa.** Sono ciò che tiene in piedi
l'invariante offline:

```gdscript
func _ready() -> void:
	_auth = get_node_or_null("/root/Auth")
	# Backend segnaposto (test headless, sviluppo locale), sessione gia' valida o
	# scelta "ospite" gia' fatta: non c'e' niente da chiedere.
	if _auth == null or not _auth.is_configured() or _auth.is_logged_in() or _auth.is_guest():
		_go_to_menu()
		return
	_auth.login_completed.connect(_on_login_completed)
	_auth.session_restore_finished.connect(_on_restore_finished)
	_build()
	_set_state(State.RESTORING if _auth.restore_pending() else State.LOGIN)
```

`_go_to_menu()` usa `get_tree().change_scene_to_file("res://ui/menu.tscn")` — **mai** un
`call_deferred` fatto a mano: il cambio scena da `_ready()` è già differito da Godot.

**9b. Struttura visiva**, stesse convenzioni di `ui/menu.gd`:

- `add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))` + `add_child(CastleBackdrop.new())`;
- `MarginContainer` con gli **stessi margini del menu** (`CastleBackdrop.COLUMN_W + 14` ai lati,
  `SPRING_Y + 16` sopra, `FLOOR_H + 6` sotto), così i campi non salgono sulla pietra;
- `VBoxContainer` con `separation` 16: titolo → campi → azioni → errore.

**9c. Tre stati**, che ricostruiscono solo la colonna centrale:

| Stato | Contenuto |
|---|---|
| `RESTORING` | Solo "Accesso in corso…" (`Style.TEXT_DIM`), nessun campo. Si esce alla `session_restore_finished` |
| `LOGIN` | `LineEdit` email + `LineEdit` password (`secret = true`), primario "ACCEDI", link "Non hai un account? Registrati" |
| `SIGNUP` | email, password, conferma password, nome giocatore; primario "CREA ACCOUNT", link "Hai già un account? Accedi" |

Sotto, in `LOGIN` e `SIGNUP`:

- separatore con etichetta "oppure" (`Style.TEXT_DIM`);
- **"Continua con Google"** → `Style.apply_plate(btn, Style.BLUE, Style.BLUE_DEEP)`, chiama
  `_auth.login_google()`;
- **"Gioca come ospite"** → `flat = true`, `font_color = Style.TEXT_DIM`, come il pulsante "Esci"
  del menu; chiama `_auth.continue_as_guest()` e poi `_go_to_menu()`;
- una `Label` d'errore, `autowrap_mode = TextServer.AUTOWRAP_WORD_SMART`, colore
  `Color(0.92, 0.42, 0.40)`, nascosta quando il testo è vuoto.

Stili: primario `Style.apply_plate(btn, Style.GOLD, Style.GOLD_DEEP, 18, 6)` con
`font_color = Style.INK`; titolo `font_size` 26+, `Style.GOLD`. Altezze: ogni pulsante almeno
`Style.TOUCH_MIN` (96), il primario `Style.TOUCH_PRIMARY` (132). I `LineEdit` prendono
`Style.box(Style.PLATE_DARK, Style.PLATE)` come stylebox `normal` e `focus`, altezza 72,
`font_size` 20. Il campo email: `keep_editing_on_text_submit = false`, e `text_submitted` collegato
alla stessa callback del pulsante primario.

**9d. Comportamento**:

- Validazione client **prima** di inviare, con `Auth.email_looks_valid()` / `Auth.password_problem()`;
  in `SIGNUP` anche "Le password non coincidono." e nome giocatore non vuoto. Messaggi in italiano
  nella `Label` d'errore, niente popup.
- Durante una richiesta: tutti i pulsanti `disabled = true` e il primario con testo "…", per evitare
  doppi invii.
- `_on_login_completed(success, reason)`: `true` → `_go_to_menu()`; `false` → riabilita i pulsanti e
  mostra il messaggio, tradotto:

```gdscript
const REASONS := {
	"email_taken": "Questa email è già registrata. Prova ad accedere.",
	"invalid_credentials": "Email o password non corretti.",
	"invalid": "Controlla email e password.",
	"rate_limited": "Troppi tentativi. Riprova tra qualche minuto.",
	"db": "Servizio non disponibile, riprova più tardi.",
	"google": "Accesso con Google non riuscito.",
}
```
  con un fallback generico ("Accesso non riuscito.") per le `reason` non mappate.
- `_on_restore_finished(success)`: `true` → `_go_to_menu()`; `false` → `_set_state(State.LOGIN)`.

---

## 10. Punti di ingresso e uscita

**`project.godot`**: `run/main_scene="res://ui/login.tscn"`.
I test caricano `res://ui/menu.tscn` esplicitamente, quindi non sono toccati dal cambio.

**`ui/menu.gd::_start_pvp()`**: un ospite deve poter fare l'upgrade. Dove oggi c'è
`auth.login_google()` più la connessione one-shot a `login_completed`, mettere il rimando alla
schermata:

```gdscript
	if auth.is_logged_in():
		get_tree().change_scene_to_file(LOBBY_SCENE)
		return
	# Ospite che vuole giocare online: sceglie li' come identificarsi, invece di
	# ritrovarsi il browser aperto su Google senza alternative.
	get_tree().change_scene_to_file("res://ui/login.tscn")
```

`_on_pvp_login_completed` e la connessione `CONNECT_ONE_SHOT` diventano morte: rimuoverle.

**`ui/settings_panel.gd`**: oggi la card Account esiste solo da loggati e non ha né logout né login.
Aggiungere, con lo stile già usato lì:

- da loggati, sopra all'"Elimina account" rosso: **"Esci dall'account"**
  (`Style.apply_plate(btn, Style.BLUE, Style.BLUE_DEEP)`) → `auth.logout()` e poi
  `change_scene_to_file("res://ui/login.tscn")`;
- da ospiti (card oggi assente): una riga "Stai giocando come ospite" + **"Accedi"** →
  `change_scene_to_file("res://ui/login.tscn")`.

Senza uno dei due un ospite resta ospite per sempre, perché la scelta è persistita in `profile.cfg`.

---

## 11. Test

**`tests/auth_smoke.gd`** — estendere, non riscrivere. Le asserzioni esistenti restano valide
(backend non configurato nei test). Aggiungere, sfruttando lo stesso frame-pump:

- `res://ui/login.tscn` si istanzia e, con backend non configurato, **passa dritta al menu**: dopo
  un paio di frame `current_scene.scene_file_path == "res://ui/main.tscn"` non ancora, ma
  `"res://ui/menu.tscn"` sì;
- `Auth.login_email("a@b.it", "password1")` senza backend emette `login_completed(false, …)` e non
  crasha; idem `Auth.register_email(...)`;
- `Auth.email_looks_valid` sui casi limite: `""`, `"senzachiocciola"`, `"a@b"`, `"a b@c.it"` falsi;
  `"a@b.it"` vero;
- `Auth.password_problem("1234567") != ""` e `Auth.password_problem("12345678") == ""`;
- `Auth.continue_as_guest()` → `is_guest()` vero; `Auth.logout()` → `is_guest()` falso.
  **Salvare e ripristinare** il valore originale di `Profile.guest_mode` a inizio e fine test: il
  test scrive su `user://profile.cfg` reale.

**`tests/net_smoke.gd`** — aggiornare l'asserzione `PROTOCOL_VERSION == 2` a `== 3` in
`_test_protocol`.

Le RPC SQL non sono coperte da test automatici (come `upsert_google_account` oggi): si verificano a
mano con i comandi della sezione 1.

---

## 12. Documentazione

- `CLAUDE.md`: aggiungere `ui/login.gd` ("schermata di accesso: Google, email/password, ospite — è
  la nuova scena principale") e `ui/castle_backdrop.gd` ("facciata del castello disegnata a runtime,
  condivisa da menu e login") alla tabella dei file; correggere il paragrafo sull'identità (non è più
  solo Google) e `PROTOCOL_VERSION` a 3; aggiornare la riga "`ui/menu.gd` — start screen — **this is
  the main scene**".
- `SETUP_DB.md`: nota che va applicata la migrazione `0003_email_password.sql`.

---

## 13. Verifica finale

1. Import obbligatorio dopo i nuovi `class_name`:
   ```sh
   godot --headless --path . --import
   ```
2. Suite headless. Le **tre** rotture note e preesistenti (`il suggerimento del negozio compare
   all'avvio`, `la vendita restituisce oro`, `la guida non è ancora stata vista`) restano tali:
   nessun test nuovo deve fallire, nessun test verde deve diventare rosso.
   ```sh
   godot --headless --path . --script res://tests/run_tests.gd
   godot --headless --path . --script res://tests/auth_smoke.gd
   godot --headless --path . --script res://tests/net_smoke.gd
   godot --headless --path . --script res://tests/menu_smoke.gd
   godot --headless --path . --script res://tests/ui_smoke.gd -- --seed=4242
   ```
3. Controllo visivo — **senza** `--headless`, il viewport headless non produce immagini. Lo sfondo
   del login deve essere identico a quello della home e i campi non devono finire sulla pietra:
   ```sh
   godot --path . --script res://tests/screenshot.gd -- <dir>
   godot --path .          # navigazione a mano: login -> menu
   ```
4. Database: applicare `0003` sul Postgres locale e ripetere i cinque `psql` della sezione 1.
5. End-to-end contro la VPS: registrazione con email → si entra; riavvio del gioco → si entra
   **senza** login (token ripristinato); "Esci dall'account" da Impostazioni → si torna alla
   schermata di login; "Gioca come ospite" → riavvio → si va dritti alla home; da Impostazioni
   "Accedi" → si torna alla schermata.
