# Report di bilanciamento — sessione bot-vs-bot

Strumento: `tools/balance_sim.gd` (singolo processo) o, preferibile,
`tools/balance_sim_parallel.sh --matches=150 --seed=1` (6 processi Godot in
parallelo, stesso identico report in ~1/4-1/5 del tempo). JSON grezzo in
`tools/.balance_run/merged.json` dopo ogni run parallela.

## Stato di partenza (bilanciamento originale, mai toccato)
- Partite finivano in **~9,4 round** su 40 previsti (8 stage × 5).
- Costo 4-5 **mai schierati**: metà del roster non esisteva nelle partite reali.
- Galli sotto banda (`gaul@2` 42% vs 57-60% delle altre sinergie).
- `legionary@2` dominante (61%, quasi gratuito con due unità costo-1 qualsiasi).
- Balistari l'unità peggiore (33%).
- I bot non vendevano mai unità (nessuna chiamata a `Player.sell()` in
  `bot_brain.gd`): l'economia simulata era più povera di quella di un
  giocatore che liquida il sottoboard.

## Modifiche applicate (in ordine)
| Area | Modifica |
|---|---|
| Durata partita | `starting_hp` 20→55, `damage_to_player.stage_base` e `per_surviving_unit` ammorbiditi su tutti gli stage |
| Livellamento | `xp_per_round` 2→4 |
| Negozio | `shop_odds` livelli 7-9 spostati verso il costo 5; `pool.copies_per_cost.5` 10→14 |
| Sinergie | `legionary@2` attenuata (hp_percent 0.18→0.12), `legionary@4` attenuata (0.40→0.28); `gaul@2` rinforzata con bonus flat non condizionato alla morte di alleati |
| Unità | Balistari ribuffato (danno/velocità/resistenze); Pretoriano nerfato due volte; Arminio e Solduros nerfati dopo l'apertura del costo 5 |
| IA bot | `core/bot_brain.gd`: i bot ora **vendono** la panchina più debole quando serve fare spazio a un acquisto voluto o per finanziare l'ultimo salto di livello |
| Strumenti | `tools/balance_sim.gd` (+`--out=`, tracciamento livello finale), `tools/balance_sim_parallel.sh`, `tools/merge_shards.py`, `tools/print_report.py` — esecuzione parallela su 6 processi |

Tutte verificate con `tests/run_tests.gd`: **160/160 superati** dopo ogni
modifica, nessuna regressione (determinismo del combattimento incluso).

## Stato finale (150 partite, seed 1, esecuzione parallela)
- Durata partita: **31,9 round medi** (da 9,4), pareggi 4,1%, livello finale medio 7,0 (massimo osservato 9).
- **Tutti i costi ora si vedono**, incluso il costo 5:

| Unità | Costo | Round schierati | Winrate |
|---|---|---|---|
| Arminio | 5 | 138 | 79,6% |
| Catafratto | 5 | 132 | 66,0% |
| Solduros | 5 | 90 | 75,6% |
| Campione gallico | 4 | 3.384 | 57,5% |
| Pretoriano | 4 | 2.714 | 48,8% |
| Ariete da guerra | 4 | 3.228 | 49,2% |
| (costo 1-3) | — | 12.000-22.700 ciascuna | 43,5-53,5% |

- Il resto del roster (costo 1-3) sta in una banda sana **43,5-58%**, nessuna
  anomalia oltre l'atteso.

## Nota di metodo importante: il costo 5 resta un caso a parte
Ho provato a nerfare Arminio e Solduros dopo averli visti sopra l'80% di
winrate (hp -12%, danno ability -20%, omnivamp di Solduros dimezzato). Il
winrate si è mosso pochissimo (Arminio 81,5%→79,6%, Solduros 84,4%→75,6%),
lo stesso fenomeno già visto con Pretoriano in una sessione precedente:
**a questo numero di copie il winrate riflette soprattutto "chi lo schiera
sta già vincendo la partita", non il potere grezzo del kit** — il costo 5 lo
compra solo il bot già in vantaggio, quindi anche tagliando le statistiche il
campione resta selezionato verso i vincitori. Continuare a nerfare sulla base
di questo numero avrebbe rendimenti decrescenti.

Per misurare il vero potere del costo 5 servirebbe un metodo diverso da
"guarda il winrate in partite libere": scontri diretti a formazione fissata
(stesso team tranne l'unità in test) o un bot che valuta le unità invece di
comprare per euristica fissa. Lasciato come lavoro futuro, non ho continuato
a tagliare i numeri a caso.

## Secondo round: 10 iterazioni contro disparità d'uso e durata (seguito)

Obiettivi posti dall'utente: winrate omogenei, uso omogeneo dentro ogni fascia
di costo, partita da 15-20 minuti reali. Dieci iterazioni, ciascuna verificata
con `tests/run_tests.gd` e con simulazioni **multi-seed** (1, 777, 4242) —
necessario perché il costo 5, a campione piccolo, mostra swing enormi da un
seed all'altro (es. Arminio: 28% con seed 1, 76% con seed 777, stessa identica
scheda unità) puramente per fortuna di abbinamenti, non per potenza del kit.
Sommare più seed con `tools/merge_shards.py` è l'unico modo per distinguere
segnale da rumore su un'unità che appare ~1 round ogni 40-50.

Leve usate, tutte in `data/*.json` (nessun limite imposto sull'entità della
modifica, come richiesto):
- `rounds.preparation_seconds` 30→18 (leva diretta sulla durata reale, senza
  toccare quanti round/livelli si raggiungono — la preparazione è tempo reale,
  il progresso di livello è legato ai round, non ai secondi)
- Ulteriore ammorbidimento di `damage_to_player` e boost di `xp_per_round`/
  odds del negozio per il costo 5, per portare più partite a livello 8-9
- Riequilibrio diretto delle 5 unità peggio o meglio posizionate di ogni
  fascia (Sagittario, Vestale, Equite, Guerriero del clan, Cavaliere Cherusco,
  Ariete da guerra, Balistari — buff; Pretoriano, Catafratto, Arminio,
  Solduros — nerf poi parziale contro-buff)
- **Fix strutturale di Solduros**: la sua abilità aveva `"self_only": true`,
  quindi il bonus di velocità d'attacco e il vampirismo (che per Arminio e
  Catafratto si applicano a tutta la squadra) valevano solo per lui. Toglierlo
  ha risolto la sua debolezza cronica molto meglio di qualunque buff ai numeri.

### Risultato finale (450 partite, 3 seed, 14.374 round totali)

| Obiettivo | Prima (fine sessione precedente) | Dopo |
|---|---|---|
| Durata partita | ~26 min | **19,6 min** ✅ |
| Range winrate (unità n≥30) | 36,1 punti (43,5%-79,6%) | **11,9 punti (47,6%-59,5%)** ✅ |
| Rapporto uso max/min, costo 1 | 1,10x | 1,04x |
| Rapporto uso max/min, costo 2 | 1,21x | 1,10x |
| Rapporto uso max/min, costo 3 | 1,10x | 1,06x |
| Rapporto uso max/min, costo 4 | 1,25x | 1,13x |
| Rapporto uso max/min, costo 5 | 1,53x | 1,67x* |

\* il costo 5 resta il più rumoroso per costruzione (appena 230-340 round su
14.374 totali, ~1 ogni 45): il rapporto max/min oscilla ancora molto da una
run all'altra nonostante la potenza delle tre unità sia ormai comparabile
(48,2%-59,5% su 450 partite).

### Incidente in corso d'opera (trasparenza)
A metà di questo secondo round, un'altra sessione ha rifattorizzato
`tools/balance_sim.gd` estraendo l'accumulatore in un nuovo `core/unit_telemetry.gd`
(condiviso ora anche da partite locali/online, non solo dalla simulazione) —
cambiamento compatibile e lasciato stare come da istruzioni. Ha però causato
un crash temporaneo (classica trappola della cache classi di Godot su un
nuovo `class_name`, già nota) che ha invalidato una run intermedia; rifatta
pulita con un `--import`, nessun dato finale ne risente.

## Cosa lascerei aperto
- Costo 5 resta strutturalmente il campione più piccolo e più rumoroso — non
  è un difetto risolvibile solo con i numeri, è la rarità voluta dal design.
  Per affinarlo oltre servirebbero scontri diretti a formazione fissata,
  non partite libere.
- `gaul@6`, `roman@6`, `teuton@6` restano molto forti (74-90%) ma con lo
  stesso identico bias di selezione del costo 5 (solo il leader ci arriva).
- Nessuna modifica di questa sessione è stata committata.
