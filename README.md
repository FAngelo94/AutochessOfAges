# Autochess Of Ages

Auto battler ambientato tra le civiltà antiche. Civiltà iniziali: **Romani**, **Galli**, **Teutonici**.
Godot 4.7, GDScript.

## Come è organizzato

```
core/           simulazione pura — nessun Node, nessuna UI
data/           tutto il bilanciamento in JSON
monetization/   negozio: interfaccia + backend RevenueCat (vedi monetization/README.md)
app/            stato persistente del giocatore (preferenze, statistiche)
ui/             presentazione (legge lo stato, non lo modifica)
android/        plugin Kotlin per RevenueCat (vedi android/README.md)
web/            ponte JavaScript per l'export HTML5 (vedi web/README.md)
tests/          suite headless
```

La regola che tiene in piedi tutto il resto: **`core/` non conosce `ui/`**. La simulazione è
deterministica e seedata, quindi la stessa partita può essere rigiocata identica. È il
prerequisito per il multiplayer autoritativo (il server simula, il client ripete) e per i test
di bilanciamento riproducibili.

| File | Ruolo |
|---|---|
| `core/rng.gd` | xorshift64\* scritto a mano — `RandomNumberGenerator` non garantisce lo stesso stream tra versioni/piattaforme |
| `core/game_data.gd` | carica e memorizza i JSON di `data/` |
| `core/unit_pool.gd` | pool **condiviso**: le copie sono finite e contese tra tutti i giocatori |
| `core/player.gd` | oro, vita, livello, panchina, griglia, negozio, fusioni a stelle |
| `core/trait_resolver.gd` | formazione → bonus effettivi per unità |
| `core/combat_sim.gd` | risolutore di battaglia a passo fisso, con log di eventi |
| `core/match_state.gd` | round, accoppiamenti, danni, eliminazioni |
| `core/bot_brain.gd` | IA di preparazione degli avversari |
| `ui/menu.gd` | schermata iniziale — **è la scena principale** |
| `ui/main.gd` | schermata di partita |
| `ui/combat_view.gd` | riproduce la battaglia leggendo il log di eventi |
| `ui/unit_slot.gd` | casella di negozio, griglia, panchina e collezione: mostra il modello 3D |
| `art/unit_portraits.gd` | renderizza ogni modello una volta e ne conserva la texture (autoload `Portraits`) |
| `ui/collection_panel.gd` | enciclopedia delle unità, generata da `data/` |
| `ui/store_panel.gd` | schermata degli acquisti |
| `app/profile.gd` | civiltà preferita, velocità delle battaglie, statistiche (autoload `Profile`) |

## Test

```sh
godot --headless --path . --script res://tests/run_tests.gd                 # motore: 59 test
godot --headless --path . --script res://tests/ui_smoke.gd -- --seed=4242   # partita: 37 test
godot --headless --path . --script res://tests/menu_smoke.gd               # menu: 19 test
```

`ui_smoke` **richiede un seed fissato**: senza, ogni esecuzione compra unità diverse e il
test fallisce a intermittenza. Il seed si fissa anche giocando, per riprodurre una partita
identica: `godot --path . -- --seed=4242`.

Per guardare il risultato invece di dedurlo, `tests/screenshot.gd` salva due schermate
(preparazione e battaglia). Va eseguito **senza** `--headless`, perché in headless il
viewport non produce immagini:

```sh
godot --path . --script res://tests/screenshot.gd -- C:/percorso/di/destinazione
```

Entrambi escono con codice 1 se qualcosa fallisce. Dopo aver aggiunto script con un
`class_name` nuovo serve prima `godot --headless --path . --import`, altrimenti la cache
delle classi globali non è aggiornata e il parser non le trova. Il test più importante è quello sul **determinismo**:
se cade, il multiplayer autoritativo non è più possibile e i numeri di bilanciamento non
valgono nulla.

## Aggiungere una civiltà

1. Una voce in `data/traits.json` sotto `origins`, con le soglie e il loro `scope`
   (`all` = tutta la squadra, `trait` = solo chi porta il tratto).
2. Almeno tante unità in `data/units.json` quante ne chiede la soglia più alta.
3. Rilanciare i test: `ogni soglia dei tratti è raggiungibile` fallisce se il roster non basta.

Nessuna modifica al codice: il motore è interamente guidato dai dati.

## Schermate

`ui/menu.tscn` è la scena principale: da lì si entra in partita, e dalla partita si torna
indietro con **Menu**. Tenerle separate invece di sovrapporre pannelli garantisce che ogni
partita parta da uno stato pulito — il cambio di scena distrugge quella precedente.

Nel menu: civiltà preferita (solo un aiuto visivo — evidenzia quella civiltà nel negozio,
**nessun vantaggio**, perché il pool è condiviso), velocità delle battaglie, collezione e
negozio. Scegliere una civiltà non posseduta apre il negozio invece di non fare nulla.

Le schermate in `screenshots/` sono generate da `tests/screenshot.gd`.

## I modelli fuori dalla battaglia

Le stesse figure 3D usate in campo compaiono nelle caselle del negozio, della griglia, della
panchina e della collezione, al posto dei nomi scritti. Non sono viewport 3D vivi — sarebbero
una quarantina di viewport attivi per mostrare figure immobili: `Portraits` renderizza ogni
modello **una volta** in una texture e la riusa ovunque. Costo: un fotogramma per unità, speso
mentre si guarda il menu iniziale.

Dove non c'è rendering (test headless) la casella mostra il nome abbreviato: nessuna schermata
dipende dal 3D per restare utilizzabile.

## La battaglia

Il risolutore non restituisce solo un vincitore: produce lo schieramento iniziale più un
log di eventi (`move`, `attack`, `damage`, `heal`, `cast`, `stun`, `death`, `periodic`).
`ui/combat_view.gd` li rigioca senza simulare nulla, a velocità ×1/×2/×4 o saltando alla
fine. Un test verifica che rigiocando il log si ottenga **esattamente** lo stato finale
della simulazione: è lo stesso meccanismo che domani permetterà al client online di
mostrare una battaglia decisa dal server.

## Bilanciamento

Tutte le costanti stanno in `data/balance.json` — economia, interessi, curva di esperienza,
probabilità dello shop per livello, dimensione del pool, scaling per stella, danno al giocatore.
Il codice non contiene numeri magici.
