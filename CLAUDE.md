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
the backend — only `wss://` to the master. Login: the client does the Google loopback+PKCE dance
and forwards `code` to the master (`AUTH_GOOGLE`); the master holds `GOOGLE_CLIENT_SECRET`,
exchanges it, and mints its own HMAC **session token** (`server/session_token.gd`) that the client
presents in `HELLO`. No RLS (PostgREST isn't exposed; role `autochess_app` is least-privilege).

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
| `ui/menu.gd` | start screen — **this is the main scene** |
| `ui/lobby.gd` | matchmaking waiting room (queue count + 30s countdown) |
| `ui/main.gd` | in-match screen; local mode unchanged, remote mode shows prep timer + PRONTO |
| `net/auth.gd` | autoload `Auth` — Google loopback+PKCE, forwards `code` to master over a short WS; degrades to guest |
| `net/match_session.gd` | base class; `LocalSession` / `RemoteSession` back it |
| `net/protocol.gd` | `class_name Protocol` — message-type consts, `encode`/`decode` (`PROTOCOL_VERSION` 2) |
| `server/master_server.gd` | `SceneTree` script; auth (`AUTH_*`/`PROFILE_SET`), queue, 30s timer, worker routing |
| `server/session_token.gd` / `session_verifier.gd` | HMAC session token minted by the master + the instance adapter injected into `Matchmaker` |
| `server/google_oauth.gd` | server-side `code`→`id_token` exchange, validates `aud`/`iss`/`exp` (no JWKS) |
| `server/account_service.gd` | login/refresh orchestration: OAuth → `upsert_google_account` → mint session + opaque refresh |
| `server/db_client.gd` | PostgREST calls on `DB_API_URL` (loopback), no auth headers; replaces `supabase_admin.gd` |
| `server/matchmaker.gd` | socket-free queue core (testable) |
| `server/game_worker.gd` | `SceneTree` script; `match_id → MatchRunner` |
| `server/match_runner.gd` | authoritative match: prep timer, 3-level command validation, resolve, targeted logs, reconnect |
| `server/stats_writer.gd` | writes `match_history` / `player_stats` via PostgREST RPC `record_match_result` |
| `ui/combat_view.gd` | replays the battle by reading the event log |
| `ui/unit_slot.gd` | shop/board/bench/collection slot; shows the 3D model |
| `art/unit_models.gd` | procedural unit figures (see below) |
| `art/unit_portraits.gd` | renders each model once, keeps the texture (autoload `Portraits`) |
| `ui/collection_panel.gd` | unit encyclopedia, generated from `data/` |
| `ui/store_panel.gd` | purchase screen |
| `ui/guide_panel.gd` | "how to play" screen, generated from `data/tutorial.json` |
| `ui/tip_bubble.gd` | one-shot in-match tips, queued in `data/tutorial.json`, tracked in `Profile.seen_tips` |
| `app/profile.gd` | favorite civilization, battle speed, stats (autoload `Profile`) |

Autoloads (project.godot): `Profile`, `Portraits`, `Store`.

### Combat replay

`combat_sim.gd` doesn't just return a winner: it produces the initial deployment plus an event
log (`move`, `attack`, `damage`, `heal`, `cast`, `stun`, `death`, `periodic`). `combat_view.gd`
replays that log without simulating anything, at ×1/×2/×4 or skip-to-end. A test asserts that
replaying the log reproduces **exactly** the simulation's final state — the same mechanism that
will let an online client show a server-decided battle.

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

`ui/menu.tscn` is the main scene; from it you enter a match, and from a match you return via
**Menu**. Keeping them as separate scenes (instead of overlapping panels) guarantees every match
starts from a clean state, since the scene change destroys the previous one.

Favorite civilization in the menu is a **visual hint only** (highlights that civ in the shop, no
gameplay advantage, since the pool is shared). Picking an unowned civilization opens the store
instead of doing nothing.

### Unit models

Every unit figure is **procedurally generated from Godot primitives** in `art/unit_models.gd` —
no `.glb`/`.obj` files, no textures, no art assets on disk. Modifying a unit means modifying that
code. Style is low-poly/stylized; legibility comes from projected silhouette, not detail.

To add a dedicated figure for a unit, write a `_build_<id>` function and add it to the `match` in
`UnitModels.build`; without that branch the unit falls back to an archetype figure (cavalry,
siege, archer, druid, berserker, legionary), so a new unit never appears with no shape.

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

### Balance

All tunable constants live in `data/balance.json` — economy, interest, XP curve, shop odds per
level, pool size, star scaling, damage to player health. No magic numbers in code.

### Monetization

RevenueCat has **no Godot SDK**, so this layer is split into an interface (`store_backend.gd`)
and backends per platform. On desktop the game uses `mock_store.gd` and the full flow is
testable now. On Android/Web, until the native bridges are wired (`android/`, `web/`), 
`is_available()` returns false, the store is hidden, and **the game stays fully playable** with
free content — no gameplay feature may depend on the store. See `monetization/README.md`,
`android/README.md`, `web/README.md` for the bridge contracts and setup steps.

`catalog.json`'s `roster_mode` (`shared` vs `owned`) controls whether purchased civilizations join
everyone's shared pool or only the buyer's — a design decision, not a technical one.
