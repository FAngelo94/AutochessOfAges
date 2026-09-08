# Scadenze e finestre temporali

Tutte le date sono nel fuso indicato dal regolamento (PDT salvo diverso avviso) e sono
**soggette a modifica** a discrezione dello sponsor.

| Finestra | Inizio | Fine |
|---|---|---|
| **Registration Period** | ven 15 maggio 2026, 08:00 PDT | mer **30 settembre 2026, 23:45 PDT** |
| **Submission Period** | ven 31 luglio 2026, 08:00 PDT | mer **30 settembre 2026, 23:45 PDT** |
| **#BuildInPublic Engagement Period** | ~ven 31 luglio 2026, 08:00 PDT | mer 30 settembre 2026, 23:45 PDT |
| **Judging Period** | gio 1 ottobre 2026, 00:00 PDT | mar 13 ottobre 2026, 12:00 PDT |
| **Annuncio vincitori** | — | **21 ottobre 2026** |

I vincitori vengono annunciati sulla pagina Devpost, su shipaton.com e sui canali social di
RevenueCat. I trofei del gran premio e delle categorie maggiori vengono consegnati dal vivo alla
conferenza **App Growth Annual** di RevenueCat a New York (evento "The Shippies", red carpet).

## Chiarimento sull'orario di apertura

Un manager (Austin Blake) ha precisato sul forum che **Shipaton è partito a mezzanotte JST**:
un'app andata live dopo quel momento è eleggibile, anche se la data di *approvazione* dello store
è precedente. Conta la data di **go-live**, non quella di approvazione.

## Tempo residuo (aggiornato all'8 settembre 2026)

**22 giorni** alla chiusura di registrazione e submission.

Questo è il vincolo dominante di tutta la pianificazione, perché due processi esterni hanno tempi
non comprimibili:

- **Google Play production access** (requisito di **Google**, non del concorso): gli account
  sviluppatore *personali* creati dopo il **13 novembre 2023** devono, testualmente, *"run a closed
  test for their app with a minimum of 12 testers who have been opted in continuously for at least
  14 days"*. I 12 tester devono risultare **iscritti al test chiuso** per 14 giorni ininterrotti —
  non devono giocare né dare feedback: è un periodo di attesa, non una prova sul gioco.
  Finiti i 14 giorni si **fa domanda** di production access, e Google la esamina in **fino a 7
  giorni**; solo dopo si può pubblicare, e la release passa comunque dalla review normale.

  Catena completa partendo da oggi (8 settembre): 14 giorni di test → 22 settembre, domanda → fino
  al 29 settembre di review → pubblicazione il 30. **Margine zero**, e presuppone 12 tester
  reclutati oggi. Se l'account non è ancora aperto, va aggiunta prima la verifica dell'identità.

  **Non soggetti alla regola:** account di tipo *organizzazione* e account personali creati prima
  del 13 novembre 2023. Da verificare in Play Console **come prima cosa**: cambia tutta la
  pianificazione.
  Mitigazione ufficiale se la regola si applica: canale Discord `#looking-for-google-play-tester`,
  dove i partecipanti si scambiano tester (confermato dal manager Jaewoong Eum). Alternative senza
  quel vincolo: **Samsung Galaxy Store**, App Store, o pubblicazione tramite l'account di terzi già
  abilitato alla produzione.

  Fonte: https://support.google.com/googleplay/android-developer/answer/14151465
- **Review dello store**: può richiedere più giorni. Il regolamento stesso raccomanda di
  sottomettere presto e aggiornare l'app in seguito.

Nota utile: la review non deve essere passata *prima* di iniziare a integrare RevenueCat. Un
manager ha confermato che l'integrazione RevenueCat **può arrivare con un aggiornamento
successivo** alla prima release pubblica, purché sia in produzione prima della submission su
Devpost (vedi [06-faq-forum.md](06-faq-forum.md)).

## Dopo la scadenza

- Non si possono più modificare i materiali della submission, ma si può continuare ad aggiornare
  il progetto nel proprio portfolio Devpost.
- Il progetto deve restare **gratuitamente testabile dai giudici fino al termine del Judging
  Period** (13 ottobre 2026).
- Ai potenziali vincitori vengono inviati moduli (affidavit, W-8BEN per i non residenti USA) da
  restituire entro **10 giorni lavorativi**; il premio arriva entro 60 giorni dalla ricezione.
