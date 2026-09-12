# Autochess Of Ages

Auto battler ambientato tra le civiltà antiche. Civiltà iniziali: **Romani**, **Galli**, **Teutonici**.
Godot 4.7, GDScript. Giocabile in locale contro un bot, con multiplayer online autoritativo
8 giocatori (vedi `CLAUDE.md` per i dettagli di rete/backend).

## Come è organizzato

```
core/           simulazione pura — nessun Node, nessuna UI
data/           tutto il bilanciamento in JSON
monetization/   negozio: interfaccia + backend RevenueCat (vedi monetization/README.md)
app/            stato persistente del giocatore (preferenze, statistiche)
ui/             presentazione (legge lo stato, non lo modifica)
net/            rete lato client: facciata di autenticazione, sessione di partita, protocollo
server/         server autoritativo headless: master (matchmaking) + worker (partita)
db/             schema Postgres self-hosted + migrazioni (vedi db/README.md)
deploy/         file di deploy della VPS — Caddy, PostgREST, unit systemd
android/        plugin Kotlin per RevenueCat (vedi android/README.md)
web/            ponte JavaScript per l'export HTML5 (vedi web/README.md)
tests/          suite headless
tools/          simulazioni di bilanciamento, generazione icone/preview — solo sviluppo
```

La regola che tiene in piedi tutto il resto: **`core/` non conosce `ui/`** (né `net/`, né
`server/`). La simulazione è deterministica e seedata, quindi la stessa partita può essere
rigiocata identica. È il prerequisito per il multiplayer autoritativo (il server simula, il
client ripete) e per i test di bilanciamento riproducibili.

| File | Ruolo |
|---|---|
| `core/rng.gd` | xorshift64\* scritto a mano — `RandomNumberGenerator` non garantisce lo stesso stream tra versioni/piattaforme |
| `core/game_data.gd` | carica e memorizza i JSON di `data/`, eroi inclusi |
| `core/unit_pool.gd` | pool **condiviso**: le copie sono finite e contese tra tutti i giocatori |
| `core/hex.gd` | geometria della griglia esagonale del campo di battaglia |
| `core/player.gd` | oro, vita, livello, panchina, griglia, negozio, fusioni a stelle, eroe scelto |
| `core/trait_resolver.gd` | formazione → bonus effettivi per unità |
| `core/combat_sim.gd` | risolutore di battaglia a passo fisso su griglia esagonale, con log di eventi |
| `core/match_state.gd` | round, accoppiamenti, danni, eliminazioni |
| `core/bot_brain.gd` | IA di preparazione degli avversari |
| `ui/login.gd` | schermata di accesso — **è la scena principale**: Google, email/password o ospite |
| `ui/menu.gd` | schermata iniziale, raggiunta solo dopo il login; qui si sceglie anche l'eroe |
| `ui/lobby.gd` | sala d'attesa del matchmaking online |
| `ui/main.gd` | schermata di partita (locale od online) |
| `ui/battle_board_3d.gd` | scena 3D della battaglia: griglia esagonale, camera dall'alto, unità in campo |
| `ui/combat_view.gd` | riproduce la battaglia leggendo il log di eventi |
| `ui/unit_slot.gd` | casella di negozio, griglia, panchina e collezione: mostra il modello 3D, trascinabile |
| `art/unit_portraits.gd` | renderizza ogni modello una volta e ne conserva la texture (autoload `Portraits`) |
| `ui/collection_panel.gd` | enciclopedia delle unità, generata da `data/` |
| `ui/store_panel.gd` | Crowdfunding Store — il negozio non vende nulla, raccoglie donazioni verso un obiettivo |
| `ui/guide_panel.gd` | schermata "come si gioca", generata da `data/tutorial.json` |
| `app/profile.gd` | civiltà ed eroe preferiti, velocità delle battaglie, statistiche (autoload `Profile`) |

## Test

```sh
godot --headless --path . --script res://tests/run_tests.gd                 # motore + serializzazione
godot --headless --path . --script res://tests/ui_smoke.gd -- --seed=4242   # partita completa
godot --headless --path . --script res://tests/menu_smoke.gd               # menu
godot --headless --path . --script res://tests/auth_smoke.gd               # login (modalità ospite)
godot --headless --path . --script res://tests/net_smoke.gd                # matchmaking + server autoritativo
```

`ui_smoke` **richiede un seed fissato**: senza, ogni esecuzione compra unità diverse e il
test fallisce a intermittenza. Il seed si fissa anche giocando, per riprodurre una partita
identica: `godot --path . -- --seed=4242`.

Per guardare il risultato invece di dedurlo, `tests/screenshot.gd` salva le schermate
principali (menu, guida, collezione, preparazione, battaglia). Va eseguito **senza**
`--headless`, perché in headless il viewport non produce immagini:

```sh
godot --path . --script res://tests/screenshot.gd -- C:/percorso/di/destinazione
```

Tutti gli script di test escono con codice 1 se qualcosa fallisce. Dopo aver aggiunto script
con un `class_name` nuovo serve prima `godot --headless --path . --import`, altrimenti la
cache delle classi globali non è aggiornata e il parser non le trova. Il test più importante
è quello sul **determinismo**: se cade, il multiplayer autoritativo non è più possibile e i
numeri di bilanciamento non valgono nulla.

Tre test falliscono su un checkout pulito, indipendentemente da qualunque lavoro recente:
dipendono da stato locale in `user://profile.cfg` (suggerimenti/guida già visti) e uno
dall'economia della vendita. Vedi `CLAUDE.md` per i nomi esatti.

## Aggiungere una civiltà

1. Una voce in `data/traits.json` sotto `origins`, con le soglie e il loro `scope`
   (`all` = tutta la squadra, `trait` = solo chi porta il tratto).
2. Almeno tante unità in `data/units.json` quante ne chiede la soglia più alta.
3. Rilanciare i test: `ogni soglia dei tratti è raggiungibile` fallisce se il roster non basta.

Nessuna modifica al codice: il motore è interamente guidato dai dati.

## Eroi

`data/heroes.json` definisce gli **eroi**: un bonus economico opzionale scelto nel menu prima
della partita. Non sono unità — non entrano nel pool condiviso, e `origin` sceglie solo la
palette del loro modello 3D procedurale. Ogni eroe ha un tipo di abilità (es. oro extra dopo
una sconfitta, oro per ogni fusione) risolto da `core/player.gd`/`core/combat_sim.gd`.

Anche le unità normali possono avere un'abilità attivabile in battaglia
(`data/units.json` → `ability`), disattivabile globalmente con
`CombatSim.abilities_enabled` — usato da `tools/balance_sim.gd --no-abilities` per verificare
via simulazione quanto le abilità (e non solo le statistiche) pesino sul tasso di vittoria.

## Schermate

`ui/login.tscn` è la scena principale: accesso con Google, email/password o "gioca come
ospite" (offline, niente multiplayer né statistiche), poi si passa a `ui/menu.tscn`. Da lì si
entra in partita, e dalla partita si torna indietro con **Menu** (mai da capo dal login).
Tenerle separate invece di sovrapporre pannelli garantisce che ogni partita parta da uno
stato pulito — il cambio di scena distrugge quella precedente.

Nel menu: civiltà ed eroe preferiti (solo un aiuto visivo — evidenzia quella civiltà nel
negozio, **nessun vantaggio**, perché il pool è condiviso), velocità delle battaglie,
collezione, cronologia partite e negozio. Scegliere una civiltà non posseduta apre il negozio
invece di non fare nulla.

## I modelli fuori dalla battaglia

Le stesse figure 3D usate in campo compaiono nelle caselle del negozio, della griglia, della
panchina e della collezione, al posto dei nomi scritti. Non sono viewport 3D vivi — sarebbero
una quarantina di viewport attivi per mostrare figure immobili: `Portraits` renderizza ogni
modello **una volta** in una texture e la riusa ovunque. Costo: un fotogramma per unità, speso
mentre si guarda il menu iniziale.

Dove non c'è rendering (test headless) la casella mostra il nome abbreviato: nessuna schermata
dipende dal 3D per restare utilizzabile.

## La battaglia

Il campo di battaglia è una griglia **esagonale** (`core/hex.gd`): sei vicini, nessuna
diagonale. Il risolutore non restituisce solo un vincitore: produce lo schieramento iniziale
più un log di eventi (`move`, `attack`, `damage`, `heal`, `cast`, `stun`, `death`, `periodic`,
`berserk`). `ui/combat_view.gd` li rigioca senza simulare nulla — in locale sempre a ×1, la
velocità è una regola del gioco e non un'opzione dello spettatore. Un test verifica che
rigiocando il log si ottenga **esattamente** lo stato finale della simulazione: è lo stesso
meccanismo che permette al client online di mostrare una battaglia decisa dal server.

## Bilanciamento

Tutte le costanti stanno in `data/balance.json` — economia, interessi, curva di esperienza,
probabilità dello shop per livello, dimensione del pool, scaling per stella, danno al giocatore.
Il codice non contiene numeri magici.

`tools/balance_sim.gd` gioca N partite di soli bot in headless e produce un report per
unità/sinergia con lo stesso accumulatore delle partite vere; `tools/run_parallel_sim.sh`
lancia più istanze in parallelo e `tools/merge_reports.gd` ne fonde i risultati — utile per
campioni più grandi di quelli che si ottengono giocando a mano.
