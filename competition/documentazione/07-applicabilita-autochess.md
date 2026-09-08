# Che cosa significa per Autochess Of Ages

Lettura del regolamento applicata a **questo** progetto: auto battler Godot 4.7 / GDScript,
sviluppatore singolo, target Android, backend self-hosted su VPS Hetzner, monetizzazione RevenueCat
già progettata ma **non ancora attiva**.

> Questa è un'analisi, non una risposta ufficiale. Per i punti dubbi conviene aprire un thread sul
> forum Devpost o scrivere a shipaton@revenuecat.com: i manager rispondono in genere entro 24 ore.

## Verdetto di eleggibilità

| Requisito | Stato | Note |
|---|---|---|
| Progetto mai pubblicato su uno store | ✅ | Il repo esiste da mesi, ma il regolamento lo consente esplicitamente: *"A Project may have existed before the Submission Period, but it must not have been publicly released"*. Confermato anche dai manager sul forum. |
| Piattaforma eleggibile | ✅ | Export Android già configurato (`export_presets.cfg`, preset `Android`), icone adattive già presenti in `android/icons/`. |
| Prima release in produzione entro il 30/09/2026 | ⚠️ **Il rischio principale** | Vedi "Il percorso critico" più sotto. |
| SDK RevenueCat che alimenta almeno un acquisto | ⚠️ **Non ancora funzionante** | Vedi "Il buco tecnico" più sotto. |
| App scaricabile dagli USA | ⚠️ | Va impostata la disponibilità del paese in Play Console: gli USA devono essere inclusi. |
| Testabile gratis dai giudici | ✅ facile | Il gioco è **giocabile gratis** per design (`free_origins: ["roman"]`, lo store non è mai un gate). Basta dichiararlo; in più conviene comunque generare un promo code per le civiltà a pagamento. |
| Materiali in inglese | ⚠️ | L'interfaccia del gioco è in italiano. Il regolamento richiede che **video, descrizione e istruzioni di test** siano in inglese o tradotti. |
| Opera originale, IP pulita | ✅ | Nessun asset artistico su disco: i modelli sono **procedurali** (`art/unit_models.gd`), Godot è MIT. Attenzione solo a `audio/prep_theme.ogg`, unico asset esterno: serve licenza compatibile, e il video demo non deve contenere musica non licenziata. |

## Il buco tecnico: RevenueCat su Godot

Il requisito duro dell'hackathon è che l'SDK RevenueCat alimenti almeno un acquisto reale. Lo stato
attuale del progetto, per come è documentato in `CLAUDE.md`, `monetization/README.md` e
`android/README.md`:

- **RevenueCat non ha un SDK Godot.** Il progetto ha già l'architettura giusta (`store_backend.gd`
  come interfaccia, `mock_store.gd` per desktop, `revenuecat_android.gd` e `revenuecat_web.gd` come
  facciate), ma su Android `is_available()` **restituisce false**: lo store è nascosto e il gioco
  resta interamente giocabile senza.
- Il ponte nativo esiste **come sorgente**: `android/revenuecat_plugin/` con
  `RevenueCatGodotPlugin.kt`. Non è mai stato compilato: `android/plugins/` **non esiste**, quindi
  non c'è nessun `.aar`.
- `data/catalog.json` ha `revenuecat.android_api_key` **vuoto**.

Per essere eleggibili serve quindi, nell'ordine:

1. Scaricare `godot-lib.4.7.stable.template_release.aar` in
   `android/revenuecat_plugin/libs/`, compilare con `./gradlew :revenuecat_plugin:assembleRelease`,
   copiare `RevenueCatGodot.release.aar` + `RevenueCatGodot.gdap` in `android/plugins/`.
2. Installare il template di build Android in Godot, attivare **Use Gradle Build** e spuntare il
   plugin nelle impostazioni di export.
3. Creare i prodotti su Google Play Console con gli id già scritti in `data/catalog.json`:
   `aoa_season_pass_monthly`, `aoa_civ_gaul`, `aoa_civ_teuton`, `aoa_skin_roman_gold`.
4. Su RevenueCat: collegare l'app Play, importare i prodotti, creare gli **entitlement** con
   esattamente i nomi `season_pass`, `civ_gaul`, `civ_teuton`, `cosmetic_pack_legion`.
5. Mettere la chiave **pubblica** Android in `catalog.json` → `revenuecat.android_api_key`.
6. Verificare il flusso con il **test store** di RevenueCat (sblocca anche la milestone 3 dello
   Ship Kit), poi con un acquisto reale (milestone 5).

Attenzione al punto segnalato nel README: Godot risolve i singleton a runtime, quindi un nome
sbagliato tra Kotlin e GDScript **non dà errore di compilazione** — l'integrazione smette di
funzionare in silenzio. Va testata su dispositivo, non solo in headless.

**Nota che alleggerisce il percorso:** un manager ha confermato che l'integrazione RevenueCat
**può arrivare con un aggiornamento successivo** alla prima release pubblica, purché sia live
prima della submission su Devpost ([06-faq-forum.md](06-faq-forum.md)). Si può quindi pubblicare
prima il gioco e aggiungere la monetizzazione dopo, invece di bloccare la release sul plugin.

Se il ponte nativo si rivelasse impraticabile nei tempi, l'alternativa formalmente valida è
**RevenueCat Ads** (il regolamento accetta *"serves ads through RevenueCat Ads"* come requisito
alternativo agli acquisti) — che aprirebbe anche il **Catvertising Award**. È però un cambio di
modello di monetizzazione, non un ripiego banale.

## Il percorso critico (22 giorni)

L'ordine dei blocchi, dal più lento al più veloce:

1. **Account Google Play Console** — se non è ancora aperto: 25 $ una tantum + verifica identità
   (giorni). **Prima cosa da controllare:** se l'account è di tipo *organizzazione*, oppure
   personale creato **prima del 13 novembre 2023**, i punti 2 e 3 non ti riguardano e il percorso
   si accorcia di tre settimane.
2. **Closed testing con 12 tester** (solo account personali post-13/11/2023) — 12 tester
   **iscritti in modo continuativo per 14 giorni**, non comprimibili. È un requisito di **Google**,
   non del concorso: il concorso non chiede alcun tester. I tester non devono giocare né dare
   feedback, devono solo restare iscritti al test.
   Reclutamento: canale Discord `#looking-for-google-play-tester`.
3. **Domanda di production access** — dopo i 14 giorni; Google la esamina in **fino a 7 giorni**.
4. **Review della release di produzione** — giorni, imprevedibile, e si somma al punto 3.
5. **Plugin RevenueCat + prodotti + entitlement** — può procedere in parallelo, e può arrivare con
   un aggiornamento post-release.
6. **Materiali di submission** (video, screenshot, icona, descrizioni) — l'ultimo giorno, ma non
   sottovalutarli: i giudici non sono obbligati a installare l'app.

Partendo oggi (8 settembre) la catena 2→3→4 arriva al 30 settembre **senza margine**, e solo se i
12 tester vengono reclutati subito. Se il vincolo non è superabile in tempo, restano tre strade
lecite: il **Samsung Galaxy Store**, che è uno store eleggibile senza requisito di tester e che
aprirebbe anche la categoria **Best App for Galaxy**; l'**App Store**, se hai accesso a un Mac e a
un account Apple Developer; oppure pubblicare attraverso l'account sviluppatore di qualcun altro
già abilitato alla produzione — esplicitamente permesso dai manager, che chiedono di aggiungere il
proprio account Google come utente dell'app in Play Console per la verifica dell'autorialità.

## Categorie a cui candidarsi

Si può concorrere a tutte quelle per cui si è eleggibili, con la stessa submission.

| Categoria | Fit | Che cosa serve in più |
|---|---|---|
| **Best Game Award** (20k/10k/5k) | 🎯 **La candidatura principale** | Descrizione di gameplay, direzione artistica e di come la monetizzazione si adatta al genere. Un auto battler con roster condiviso e finito è un argomento forte: il `roster_mode: "shared"` è **una scelta di design che protegge l'equità competitiva** — è esattamente il tipo di ragionamento "monetization fit for the genre" che il criterio chiede. |
| **RevenueCat Design Award** (20k/10k/5k) | 🎯 Fit alto e sottovalutato | Il criterio *Innovative ideas* premia "innovazioni tecniche integrate nel prodotto": qui c'è una storia tecnica vera — **ogni figura è generata proceduralmente da primitive Godot, zero asset artistici su disco**, più il castello disegnato a runtime (`CastleBackdrop`). Va indicato ai giudici dove guardare: la replay della battaglia, l'accelerazione berserk, la vetrina dei modelli. |
| **HAMM Award** (20k/10k/5k) | ⚠️ Possibile ma esigente | Chiede numeri di conversione o ricavi. Con pochi giorni di vita dell'app, la parte narrativa (paywall, pricing, packaging, il ragionamento `shared` vs `owned` in `catalog.json`) è forte; i numeri saranno deboli. |
| **#BuildInPublic** (30k/20k/10k) | ✅ Ancora recuperabile | Il periodo di engagement è aperto fino al 30 settembre e **la dimensione dell'audience non conta**. Post taggati `#Shipaton` sul percorso di sviluppo — il multiplayer autoritativo, il determinismo del simulatore, il deploy sulla VPS — sono materiale ottimo. Servono link ai post nel form. |
| **Grand Prize** (100k) | ⚠️ Improbabile | La shortlist si basa sui **ricavi totali riportati in RevenueCat durante il Submission Period**. Con l'app pubblicata a fine periodo il fatturato sarà minimo. Candidarsi comunque costa solo una descrizione. |
| **Catvertising** (20k/10k/5k) | ➖ Solo se si sceglie RevenueCat Ads | Cambierebbe il modello di monetizzazione. |
| **Best App for Galaxy** | ➖ Opzione tattica | Diventa interessante se il Galaxy Store serve ad aggirare il blocco dei 12 tester di Google Play. |
| **Keep Them Coming Back** (OneSignal, 25k/15k/5k) | ➖ A basso costo | Basta **una** campagna push deployata per essere eleggibili. Richiede però un altro ponte nativo Android, quindi realisticamente fuori portata in 22 giorni. |
| **Ship Kotlin Everywhere**, **Idea to Income**, **Most Viral App**, **Growth Loop**, **Funnel Vision** | ❌ | Richiedono rispettivamente KMP, Replit, Noise, SDK Layers, Stripe+Funnels: tutti incompatibili con lo stack attuale nei tempi disponibili. |
| **Next Gen Award** | ❌ | Solo studenti attivi con email accademica. |
| **Peace Prize**, **Influencer Awards** | ❌ | Nessuna attinenza (la categoria Gaming di Mr Lewis Blogs è un *backlog tracker*, non un gioco). |

## Materiali: note specifiche per questo progetto

- **Screenshot 1179×2556 senza cornice.** Il progetto ha già lo strumento giusto:
  `godot --path . --script res://tests/screenshot.gd -- <dir>` produce menu, guida, collezione,
  preparazione e battaglia (**va lanciato senza `--headless`**, la viewport non renderizza in
  headless). Va impostata la risoluzione richiesta e vanno rimossi eventuali frame.
  `tools/preview_shot.gd` genera la vetrina dei modelli, ottima come immagine di supporto.
- **Icona 1024×1024.** Esiste già `icon.svg` e il pipeline `tools/make_icon.py` /
  `tools/rasterize_icon.gd`: serve l'export PNG a 1024.
- **Video < 2 minuti, su YouTube o Vimeo, pubblico.** Deve mostrare il gioco **in funzione sul
  dispositivo** — quindi cattura da telefono o da emulatore Android, non da desktop. Suggerimento:
  usare `--seed=NNNN` per registrare una partita riproducibile e montare il meglio.
  ⚠️ Niente musica non licenziata: `audio/prep_theme.ogg` va usato solo se la licenza lo permette.
- **Lingua.** Il video ha bisogno di voice-over o sottotitoli in inglese, e la descrizione va
  scritta in inglese. Localizzare l'interfaccia non è richiesto dal regolamento, ma i giudici
  useranno un'app in italiano: sottotitoli espliciti o una traccia inglese dell'UI aiutano
  concretamente il punteggio.
- **Free trial / promo code.** Il gioco è già giocabile gratis con i Romani, quindi il requisito è
  soddisfatto; conviene comunque generare promo code Play per le civiltà a pagamento e includerli
  nelle testing instructions.
- **Backend.** La modalità ospite offline e il fallback al menu quando il backend non è configurato
  (`ui/login.gd`) sono una garanzia utile: se la VPS non risponde durante il judging, l'app resta
  giocabile. Vale la pena dirlo nelle istruzioni di test. Verificare comunque che la VPS regga il
  periodo di giudizio (fino al **13 ottobre**), perché il regolamento richiede che il progetto resti
  testabile fino alla fine del Judging Period.

## Prossimi passi concreti, in ordine

1. Registrarsi su Devpost (**Join Hackathon**) e compilare il **participant form** → sblocca lo
   Ship Kit. Da fare oggi: la registrazione chiude insieme alla submission.
2. Aprire/verificare l'account Google Play Console e **avviare subito il closed testing** con 12
   tester (Discord `#looking-for-google-play-tester`). È il vincolo più lungo.
3. In parallelo: compilare l'`.aar` del plugin RevenueCat, creare prodotti ed entitlement, riempire
   `android_api_key`, fare un acquisto di test.
4. Iniziare a postare con `#Shipaton` per il #BuildInPublic — anche in stealth, se preferito.
5. Preparare video, screenshot e icona quando la build Android è stabile, non l'ultimo giorno.
6. Pubblicare in produzione, poi completare la submission Devpost candidandosi a **Best Game**,
   **Design**, **#BuildInPublic** e (facoltativo) **HAMM** e **Grand Prize**.
