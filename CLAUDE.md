# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Autochess Of Ages — auto battler set among ancient civilizations (Romans, Gauls, Teutons, more
planned). Godot 4.7, GDScript. Single-player vs. bot now, architected for authoritative online
multiplayer later.

Godot is not on PATH. Executable:
`C:\Users\afalc\Downloads\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe`
(use the `_console` variant to see stdout output).

## Commands

Run tests (headless):

```sh
godot --headless --path . --script res://tests/run_tests.gd                 # engine + serialization
godot --headless --path . --script res://tests/ui_smoke.gd -- --seed=4242   # full match
godot --headless --path . --script res://tests/menu_smoke.gd               # menu
godot --headless --path . --script res://tests/auth_smoke.gd               # login facade (guest mode)
godot --headless --path . --script res://tests/net_smoke.gd                # matchmaking + authoritative worker
```

Three tests currently fail on a clean checkout, unrelated to multiplayer work and pre-dating it —
they depend on local `user://profile.cfg` state (tips/guide marked seen) and one on sell economics:
`il suggerimento del negozio compare all'avvio`, `la vendita restituisce oro`,
`la guida non è ancora stata vista`.

`ui_smoke` **requires a fixed seed** — without one each run buys different units and the test
fails intermittently. The same `--seed=NNNN` flag works when playing normally, to reproduce an
identical match: `godot --path . -- --seed=4242`.

Both test scripts exit with code 1 on failure. The most important test is the **determinism**
one: if it breaks, authoritative multiplayer is no longer possible and balance numbers are
meaningless.

After adding a script with a new `class_name`, run an import first, or the global class cache is
stale and the parser won't find it:

```sh
godot --headless --path . --import
```

Balance report from real local matches (after playing some games offline):

```sh
godot --headless --path . --script res://tools/unit_balance.gd
```

Visual verification (must run **without** `--headless` — the viewport produces no image
headless):

```sh
godot --path . --script res://tests/screenshot.gd -- <dest_dir>       # menu.png, guida.png, collezione.png, preparazione.png, battaglia.png
godot --path . --script res://tools/preview_shot.gd -- <dest_dir>     # showcase of all unit models
                                                                       # append roman/gaul/teuton to zoom one civ
```

## Architecture

```
core/           pure simulation — no Node, no UI
data/           all balance numbers as JSON
monetization/   store: interface + RevenueCat backends (see monetization/README.md)
app/            persistent player state (preferences, stats)
ui/             presentation (reads state, does not mutate it)
net/            client networking: auth facade, session abstraction, wire protocol
server/         headless authoritative server: master (matchmaking) + worker (match)
db/             self-hosted Postgres schema + migrations + apply.sh (see db/README.md)
deploy/         VPS deploy files — Caddy, PostgREST, systemd units, backup (see SETUP_VPS.md)
android/        Kotlin plugin for RevenueCat (see android/README.md)
web/            JS bridge for the HTML5 export (see web/README.md)
tests/          headless test suites
```

Multiplayer (see `MULTIPLAYER_PLAN.md` for the original design; `SELFHOST_PLAN.md` +
`SETUP_DB.md` + `SETUP_VPS.md` for the current self-hosted backend — no Supabase). `core/` gained
pure `to_dict()`/`apply_dict()` serialization and still knows nothing about `net/` or `server/`.
`ui/main.gd` drives a `MatchSession` (`net/match_session.gd`): `LocalSession` owns a real
`MatchState` (offline, unchanged behaviour), `RemoteSession` fills its `MatchState` only from
server snapshots — it never simulates. Online, the client is never authoritative and never sees
another player's private state (`Player.to_dict(viewer=false)` omits shop/gold/bench). Transport
is WebSocket (`wss://`, TLS via Caddy), messages are `var_to_bytes`-encoded dicts
(`net/protocol.gd`), not JSON — preserves `Vector2i`.

**Backend = one VPS.** Postgres + PostgREST (loopback :3000) + master + worker + Caddy on a
single Hetzner box; the only external service is Google (login). The client never talks HTTP to
the backend — only `wss://` to the master. Identity is Google **or** email/password (added in
`db/migrations/0003_email_password.sql`), never both required: `profiles.google_sub` is nullable,
an account has `google_sub`, `password_hash`, or both. Login: for Google, **the server closes the
consent**, not the app — the client asks the master for a consent URL
(`AUTH_GOOGLE_BEGIN` → `AUTH_GOOGLE_URL`), opens the system browser, and Google redirects to
`https://<host>/oauth/cb`, the master's only HTTP route (`server/oauth_http.gd`, behind Caddy). The
master exchanges the `code` (it holds `GOOGLE_CLIENT_SECRET`) and parks the session under the
`state` (`server/oauth_pending.gd`, one-shot, 10 min TTL); the client picks it up with
`AUTH_GOOGLE_POLL` when it comes back to the foreground. The old loopback+PKCE flow (RFC 8252,
a `TCPServer` inside the app) was removed because it is a **desktop** flow: on Android the
activity pauses the moment the browser opens, `_process()` stops, and the redirect is never
accepted. The client persists the pending login (`user://oauth_pending.dat`) so a login survives
the OS killing the game. The master then mints its own HMAC **session token**
(`server/session_token.gd`) that the client presents in `HELLO`. The Google OAuth client must be
of type **Web application** with that exact redirect URI (`GOOGLE_REDIRECT_URI`). For email/password, the client
sends `AUTH_EMAIL_LOGIN`/`AUTH_EMAIL_SIGNUP` and the master calls the matching Postgres RPC
(`login_email_account`/`register_email_account`, bcrypt via `pgcrypto`) — both paths converge on
the same `AccountService._issue_session()` and the same `AUTH_OK` bundle. No RLS (PostgREST isn't
exposed; role `autochess_app` is least-privilege).

`ui/login.tscn` is the actual main scene (`project.godot`): it gates the home behind a login —
Google, email/password, or "gioca come ospite" (offline, no multiplayer/stats, remembered in
`Profile.guest_mode`) — and falls straight through to `ui/menu.tscn` when the backend is
unconfigured, already logged in, or already a guest. `PROTOCOL_VERSION` is 6.

The rule that holds everything else up: **`core/` does not know about `ui/`**. The simulation is
deterministic and seeded, so the same match can be replayed identically — the prerequisite for
authoritative multiplayer (server simulates, client replays) and for reproducible balance testing.

| File | Role |
|---|---|
| `core/rng.gd` | hand-written xorshift64\* — `RandomNumberGenerator` doesn't guarantee the same stream across engine versions/platforms |
| `core/game_data.gd` | loads and caches the JSON from `data/` |
| `core/unit_pool.gd` | **shared** pool — copies are finite and contested across all players |
| `core/player.gd` | gold, health, level, bench, board, shop, star merges |
| `core/trait_resolver.gd` | formation → effective bonuses per unit |
| `core/combat_sim.gd` | fixed-step battle resolver, produces an event log |
| `core/match_state.gd` | rounds, pairings, damage, eliminations |
| `core/bot_brain.gd` | opponent prep AI |
| `ui/login.gd` | login screen — **this is the main scene**: Google, email/password, or guest |
| `ui/menu.gd` | start screen, reached only after login/guest |
| `ui/castle_backdrop.gd` | `class_name CastleBackdrop` — the runtime-drawn castle facade, shared by login and menu |
| `ui/lobby.gd` | matchmaking waiting room (queue count + 30s countdown) |
| `ui/main.gd` | in-match screen; local mode unchanged, remote mode shows prep timer + PRONTO |
| `net/auth.gd` | autoload `Auth` — Google (server-side consent: begin → browser → poll on resume) and email/password over a short WS; degrades to guest |
| `net/match_session.gd` | base class; `LocalSession` / `RemoteSession` back it |
| `net/protocol.gd` | `class_name Protocol` — message-type consts, `encode`/`decode` (`PROTOCOL_VERSION` 6) |
| `server/master_server.gd` | `SceneTree` script; auth (`AUTH_*`/`PROFILE_SET`), OAuth redirect, queue, 30s timer, worker routing |
| `server/session_token.gd` / `session_verifier.gd` | HMAC session token minted by the master + the instance adapter injected into `Matchmaker` |
| `server/google_oauth.gd` | consent URL + server-side `code`→`id_token` exchange, validates `aud`/`iss`/`exp` (no JWKS) |
| `server/oauth_pending.gd` | `state` → pending Google login (socket-free, testable): PKCE pair, one-shot pickup, TTL, cap |
| `server/oauth_http.gd` | the master's only HTTP route (`GET /oauth/cb`, loopback behind Caddy) + the browser page that offers the "back to AoA" intent |
| `server/account_service.gd` | login/refresh orchestration: OAuth → `upsert_google_account` → mint session + opaque refresh |
| `server/db_client.gd` | PostgREST calls on `DB_API_URL` (loopback), no auth headers; replaces `supabase_admin.gd` |
| `server/matchmaker.gd` | socket-free queue core (testable) |
| `server/game_worker.gd` | `SceneTree` script; `match_id → MatchRunner` |
| `server/match_runner.gd` | authoritative match: prep timer, 3-level command validation, resolve, targeted logs, reconnect |
| `server/stats_writer.gd` | writes `match_history` / `player_stats` / `match_units` via PostgREST RPC `record_match_result` |
| `ui/combat_view.gd` | replays the battle by reading the event log |
| `ui/phase_bar.gd` | `PhaseBar` — time bar shared by preparation and battle |
| `ui/unit_slot.gd` | shop/board/bench/collection slot; shows the 3D model |
| `art/unit_models.gd` | procedural unit figures (see below) |
| `art/unit_portraits.gd` | renders each model once, keeps the texture (autoload `Portraits`) |
| `ui/collection_panel.gd` | unit encyclopedia, generated from `data/` |
| `ui/history_panel.gd` | match history — merges the server's online matches with the local ones |
| `ui/store_panel.gd` | Crowdfunding Store — fixed donation tiers, progress bar to €1000, goal list |
| `ui/guide_panel.gd` | "how to play" screen, generated from `data/tutorial.json` |
| `ui/tip_bubble.gd` | one-shot in-match tips, queued in `data/tutorial.json`, tracked in `Profile.seen_tips` |
| `app/profile.gd` | favorite civilization, battle speed, stats (autoload `Profile`) |
| `app/match_log.gd` | local match history (`user://history.json`) + balance telemetry (`user://telemetry.jsonl`) |
| `core/unit_telemetry.gd` | per-unit balance accumulator, shared by the sim, local matches and the server |

Autoloads (project.godot): `Profile`, `Portraits`, `Store`.

### Combat replay

`combat_sim.gd` doesn't just return a winner: it produces the initial deployment plus an event
log (`move`, `attack`, `damage`, `heal`, `cast`, `stun`, `death`, `periodic`, `berserk`).
`combat_view.gd` replays that log without simulating anything. A test asserts that replaying the
log reproduces **exactly** the simulation's final state — the same mechanism that will let an
online client show a server-decided battle.

Own battles play at ×1 only: the pace is a rule of the game, not a viewer setting, and a
multiplier would contradict the round bar. The ×1/×2/×4 buttons survive **only** in the spectate
view, which has no bar.

### Round clock and berserk

A round is capped at `combat.max_duration_seconds` and `combat_sim.gd` keeps **two clocks**:

- `time` — the simulation clock. Units read it for cooldowns, timed effects and stuns.
- `elapsed` — the round clock, 0 → `max_duration_seconds`, always at real speed. It ends the
  battle, stamps every event (`_log`), and is the `duration` returned to the view.

From `combat.berserk_at_seconds` on, `step()` runs `combat.berserk_time_scale` sub-steps per
round tick, so everything — attacks, movement, cooldowns, DoTs — runs that many times faster
while `elapsed` advances normally. Sub-steps keep `tick_delta` intact on purpose: scaling the
step itself would coarsen the simulation exactly in the decisive seconds and change outcomes
instead of just accelerating them. Because events are stamped on `elapsed`, they bunch up in the
final seconds and the replay *visibly* speeds up with no work from the view.

When `elapsed` runs out it is **always** `Outcome.DRAW` — no remaining-HP tie-break — and
`match_state.gd` applies damage only when there is a winner, so neither player loses life.

`ui/phase_bar.gd` (`PhaseBar`) draws that clock, and the *same* widget is used for the
preparation phase at the bottom of the screen. In local mode the preparation countdown lives in
`ui/main.gd` (`_tick_preparation` / `_restart_preparation_timer`) and fires `request_ready()` at
zero, so single-player has the same rhythm as online instead of waiting forever on COMBATTI.

### Adding a civilization

1. An entry in `data/traits.json` under `origins`, with thresholds and their `scope` (`all` =
   whole team, `trait` = only units carrying that trait).
2. At least as many units in `data/units.json` as the highest threshold requires.
3. Rerun tests — `ogni soglia dei tratti è raggiungibile` fails if the roster is too small.

No code changes needed: the engine is entirely data-driven.

### Onboarding

All onboarding text — the Guide screen's chapters and the in-match one-shot tips — lives in
`data/tutorial.json`, read through `GameData.guide_sections()` / `GameData.tip(id)`. Placeholders
like `{reroll_cost}` are resolved from `data/balance.json` by `TutorialText.expand()` (the single
source both `GuidePanel` and `TipBubble` use) — never hardcode a balance number into a tutorial
string.

`TipBubble` lives in the normal layout flow (a `MarginContainer` inserted between the shop and the
action bar in `ui/main.gd`), not as an absolute-positioned overlay — an anchored overlay tried
first covered the COMBATTI button. Each tip fires once per id (`Profile.seen_tips`, a
`PackedStringArray`); when duplicating one into a local variable for a test, always
`.duplicate()` it — plain assignment shares the same buffer, and mutating the original mutates
the "saved" copy too, silently defeating the test's own restore step.

### Screens

`ui/login.tscn` is the main scene; it gates `ui/menu.tscn` behind a login (Google, email/password,
or guest) and is skipped straight to the menu when the backend is unconfigured, already logged in,
or already guest — see `tests/auth_smoke.gd` for the invariant. From the menu you enter a match,
and from a match you return via **Menu** (not back through login). Keeping these as separate
scenes (instead of overlapping panels) guarantees every match starts from a clean state, since the
scene change destroys the previous one.

Favorite civilization in the menu is a **visual hint only** (highlights that civ in the shop, no
gameplay advantage, since the pool is shared). Picking an unowned civilization opens the store
instead of doing nothing.

The viewport is `720×1280` with `keep_width`, so on a 20:9 phone the canvas is **720×1600** and
320 px belong to nobody. In the preparation screen `ui/main.gd` claims them: `CELL_SIZE`,
`SHOP_SLOT_SIZE` and `BENCH_SLOT_SIZE` are the *minimum* sizes, and `_apply_metrics()` multiplies
them by a factor solved from the space that actually exists — one shared vertical constraint, a
per-zone width cap (the board can grow much more than bench and shop, which must leave room for
their icon button). The factor never drops below 1.0, so a 16:9 screen renders exactly as before
and still scrolls.

Two traps are baked into that function and must survive any rewrite. It **awaits two frames**
before measuring: an `HFlowContainer` with no width yet declares the height of its worst case, all
children in one column, and an autowrapping `Label` wraps at every letter — measured early, the
body claims to be 2700 px tall and the solver always concludes there is no room. And it keeps
`CONTENT_HEADROOM` in reserve, because the measurement happens at round 1 when the synergy card is
one row tall and it will be three by the time the team is full; without it the scrollbar would
appear on its own after the third unit fielded. Rescaling the board on every synergy change is the
alternative, and a board that resizes mid-game is worse than a little space left free.

### Unit models

Every unit figure is **procedurally generated from Godot primitives** in `art/unit_models.gd` —
no `.glb`/`.obj` files, no textures, no art assets on disk. Modifying a unit means modifying that
code. Style is low-poly/stylized; legibility comes from projected silhouette, not detail.

To add a dedicated figure for a unit, write a `_build_<id>` function and add it to the `match` in
`UnitModels.build`; without that branch the unit falls back to an archetype figure (cavalry,
siege, archer, druid, berserker, infantry), so a new unit never appears with no shape.

Constraints learned by measuring, not assuming — apply to every new figure:
- arcs must lie flat on the horizontal plane (vertical arcs vanish under the top-down camera)
- keep colors within one figure well separated (a single brown reads as a shapeless mass)
- avoid wide horizontal plates on head/chest — in top-down view they cover the figure and read as
  lying down; prefer a ring or a vertical block
- every figure must stay inside its cell (blades/poles included), or it bleeds into neighboring
  units

`Portraits` renders each model **once** into a texture and reuses it everywhere the model appears
outside battle (shop, board, bench, collection) — avoids ~40 live 3D viewports for static
figures. Where no rendering happens (headless tests) the slot shows an abbreviated name instead;
no screen depends on 3D to remain usable.

Dropping a `.glb` file named after a unit's id (see `models/README.txt`) into that directory makes
`art/unit_models.gd` use it in place of the procedural figure for that id — no other registration
needed. Models must face **+Z** (matches procedural `FORWARD`), one board cell = 1.0 world unit.
Requires the same one-time `--headless --path . --import` before Godot picks it up.

### Match history and balance telemetry

Every match — simulated, local or online — feeds the *same* accumulator,
`core/unit_telemetry.gd` (pure, hooked to `MatchState.round_resolved`, never touches the RNG, so
attaching it cannot change a seeded match). It produces two things: light per-(match, player, unit)
rows — how many rounds a unit was fielded, how many it won, its final star — and the cumulative
report `tools/print_report.py` already knew how to print.

Where those numbers land depends on who owns the match:

- **online** — `server/match_runner.gd` passes the rows to `StatsWriter`, which writes
  `match_units` in the same transaction as the result (`db/migrations/0004_match_units.sql`). Query
  them with `db/unit_balance.sql` (view `public.unit_balance`).
- **local** — `ui/main.gd` appends one line per match to `user://telemetry.jsonl` and one entry to
  `user://history.json` (`app/match_log.gd`). Report:
  `godot --headless --path . --script res://tools/unit_balance.gd`.

The two are kept apart on purpose: a match against the bot must not move the PvP numbers, and
balance data sent by a client would be forgeable anyway.

The player reads their history in `ui/history_panel.gd` (📜 in the menu), which merges the online
matches — fetched with `HISTORY_REQUEST` through the master, never HTTP straight to the DB — with
the local ones. Guest or offline, it shows the local ones and no error.

### Balance

All tunable constants live in `data/balance.json` — economy, interest, XP curve, shop odds per
level, pool size, star scaling, damage to player health. No magic numbers in code.

`shop_odds` is not the final word on what the shop offers: `UnitPool.band_weights()` multiplies
each cost band by how many copies that band has left (`remaining / initial ^
pool.scarcity_exponent`), so a band the eight players have drained becomes rarer and its weight
spreads over the others. With a full pool the weights equal the table exactly — that invariant is
what keeps the table readable — and `pool.scarcity_exponent: 0.0` restores the nominal
distribution without touching code. A band at zero weighs zero whatever the exponent, which is
what removed the old downward fallback: drawing cost 1 when cost 1 was exhausted had no cheaper
band to fall back on and left the shop slot empty.

### Monetization — Crowdfunding Store

The store sells nothing: it collects **donations** toward a €1000 goal. Every civilization is
free (`free_origins` in `data/catalog.json`), so no gameplay feature depends on the store — a
project constraint, not an accident. The entitlement machinery still exists and `MockStore` still
exercises it, but nothing is on sale; a civilization that were neither free nor purchasable would
be permanently unselectable, which is why removing something from the store always means checking
`free_origins`.

RevenueCat has **no Godot SDK**, so this layer is split into an interface (`store_backend.gd`)
and backends per platform. On desktop the game uses `mock_store.gd` and the full flow is testable
now. On Android the bridge is a Kotlin plugin built from `android/revenuecat_plugin/` — the
`.aar` in `android/plugins/` plus `gradle_build/use_gradle_build=true` in `export_presets.cfg`
are what put the SDK inside the APK; without either, `is_available()` returns false and the store
is hidden. Two constraints are not free choices: the plugin must compile with the **same Kotlin
version as `godot-lib`** (2.1, or its metadata is unreadable), and the RevenueCat SDK must be
**>= 9.9.0** for the Test Store — hence 10.20.0, declared identically in
`android/plugins/RevenueCatGodot.gdap` (what ships) and `revenuecat_plugin/build.gradle` (what
compiles). `godot-lib.template_release.aar` need not be downloaded: it is inside Godot's own
export templates. See `android/README.md`.

`data/catalog.json` currently holds a **Test Store** key (`test_…`), which lets purchases be
tested without Google Play. `Store._select_backend()` refuses to use one in a non-debug build and
disables the store instead: RevenueCat rejects test keys in production, and a hidden store is a
better failure than a button that opens nothing.

Two constraints shape the whole design:

- **Google Play product prices are fixed** — an arbitrary amount cannot be charged, so donations
  are fixed tiers, one button each (`donations.tiers` in `data/catalog.json`). A free-amount field
  was the first design and was dropped: it promised what the payment cannot deliver, since any
  typed amount still has to land on a pre-created product. Adding an amount costs one line of JSON
  plus one product in each dashboard.
- **The database row is written by the RevenueCat webhook, never by the client.** The progress bar
  is public, so a total summed by whoever pays would be inflatable by anyone. `POST
  /revenuecat/webhook` is the master's second HTTP route (`server/oauth_http.gd`, shared port with
  the OAuth redirect, shared-secret `Authorization` header) and lands in `public.donations`
  (`db/migrations/0005_donations.sql`) via `record_donation`, idempotent on `transaction_id`
  because RevenueCat retries. The client only *reads* the total, through the master
  (`DONATIONS_REQUEST`/`DONATIONS_DATA`), like everything else.

Donations are **consumables**: repeatable, granting no entitlement — hence two separate signals
(`purchase_completed` unlocks something, `product_purchase_completed` does not) and no "restore
purchases" button in the panel. If entitlements ever go back on sale, that button must come back
with them: on Google Play it is a requirement.

`Store` calls `Purchases.logIn()` on login (`identify()` → the plugin's `logIn`). Without it the
store only knows an anonymous device id — `Store` is an autoload registered *before* `Auth`, so
`_ready()` cannot see it — purchases would not follow the player across devices, and a donation
would reach the webhook with an `app_user_id` matching no profile.
