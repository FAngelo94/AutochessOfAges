# SHIPATON_CHECKLIST.md — requisiti mancanti per RevenueCat Shipaton 2026

Confronto tra il regolamento del concorso e lo stato del progetto al 15/09/2026.

**Scadenza invio: 30 settembre 2026, 23:45 PDT.**

Fonti:
- [Regolamento ufficiale](https://revenuecat-shipaton-2026.devpost.com/rules)
- [Pagina Devpost](https://revenuecat-shipaton-2026.devpost.com/)
- [Guida di preparazione RevenueCat](https://revenuecat.github.io/codelabs/shipaton-2026-prep.html)

---

## Requisiti obbligatori mancanti

- [ ] **App pubblicata**: serve l'URL di un'app live su Google Play (o App Store / Galaxy Store), con la prima versione pubblica uscita entro il 30/9. Tutta la sezione Play Console di [`LAUNCH_CHECKLIST.md`](LAUNCH_CHECKLIST.md) è ancora da fare.
- [ ] ⚠️ **Tempi di Play Console**: un account personale nuovo richiede 14 giorni continuativi di test chiuso con almeno 12 tester, più circa una settimana di revisione per la produzione. Va verificato subito se l'account è soggetto a questo vincolo.
- [ ] **RevenueCat in produzione**: `data/catalog.json` usa ancora la chiave Test Store (`test_…`). Servono la chiave di produzione, i prodotti delle donazioni creati su Play Console e collegati a RevenueCat, e un acquisto reale verificato.
- [ ] **Materiali in inglese**: descrizione, istruzioni di test e video in inglese (o con traduzione inglese).
- [ ] **Video demo**: meno di 2 minuti, pubblico su YouTube o Vimeo, registrato sul dispositivo, senza musica protetta da copyright se non si ha il permesso (verificare la licenza di `audio/prep_theme.ogg`).
- [x] **Icona 1024×1024**: oggi esiste solo `icon.svg`.
- [ ] **Screenshot 1179×2556** senza cornice del dispositivo (almeno uno): il viewport del gioco è 720×1280, quindi va generato apposta.
- [ ] **Accesso per i giudici**: il regolamento chiede una prova gratuita o un codice promo per sbloccare gli acquisti. Oggi un acquisto non sblocca ancora nulla nell'app (le estetiche arrivano col prossimo aggiornamento): spiegarlo nelle istruzioni di test, oppure consegnare già qualcosa di visibile (anche solo un badge "sostenitore") da far vedere ai giudici con un codice promo.
- [ ] **Disponibilità negli Stati Uniti**: includerli nei paesi di distribuzione.
- [ ] **Iscrizione e invio su Devpost** entro la scadenza.

## Prerequisiti per pubblicare su Google Play

- [x] **Target SDK**: `export_presets.cfg` ha `target_sdk="36"`.
- [x] **Keystore di release** + export **AAB** firmato.
- [x] **Privacy policy** e **pagina di cancellazione account** compilate e online.
- [x] **Data safety form** e **content rating** (IARC) su Play Console.
- [x] **Consenso OAuth Google** portato da "Testing" a "In produzione".

## Da chiarire

- [ ] **Acquisti "sostenitore" con ricompensa futura.** Chi paga non fa una donazione pura: riceverà estetiche personalizzate nel prossimo aggiornamento. Per il concorso questo rafforza la posizione (è un acquisto in-app vero, fatto con l'SDK RevenueCat), ma restano alcuni punti:
  - **Testo nell'app e nella scheda Play**: oggi il negozio parla di "donazioni" (`data/catalog.json`, `ui/store_panel.gd`). Va detto chiaramente cosa si riceve e quando, altrimenti la policy di Google Play sui contenuti ingannevoli può essere un problema. Da verificare sulla policy Payments di Google Play, che non ho letto nel dettaglio.
  - **Tracciare chi ha pagato**: le estetiche andranno assegnate a posteriori. Il webhook scrive già `public.donations` con l'`app_user_id` (grazie a `Purchases.logIn()`), ma un acquisto fatto da ospite, senza login, resta legato a un id anonimo e non sarà riconducibile a un profilo. Valutare di richiedere il login per acquistare.
  - **Consumabile o non-consumabile**: se la ricompensa è un diritto permanente, un prodotto non-consumabile (o un entitlement RevenueCat) è più coerente e sopravvive ai cambi di dispositivo.
  - **Conferma sul Discord dello Shipaton** che un acquisto con consegna differita è accettato ai fini del concorso.

## Già soddisfatti

- Nessuna versione pubblica prima del periodo del concorso.
- Piattaforma Android ammessa.
- SDK RevenueCat integrato (plugin Kotlin).
- Nessun vincolo su engine (Godot) o sull'uso dell'IA.
