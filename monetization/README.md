# Monetizzazione — Crowdfunding Store

Il gioco non vende contenuti: raccoglie **donazioni** verso un obiettivo di 1000 €. Tutte le
civiltà sono gratuite (`free_origins` in `data/catalog.json`), e nessuna funzione di gioco dipende
dal negozio — vincolo di progetto, non caso fortunato.

RevenueCat **non ha un SDK per Godot**. Supporta iOS, Android nativo, Unity, Flutter, React
Native, Cordova, KMP e Web Billing. Per usarlo da Godot serve un ponte, ed è per questo che lo
strato è diviso in un'interfaccia e più backend.

## Stato

| Componente | Stato |
|---|---|
| `store_backend.gd` — interfaccia comune | completo |
| `mock_store.gd` — negozio finto per lo sviluppo | completo e funzionante |
| `catalog.gd` + `data/catalog.json` — tagli, obiettivo, entitlement | completo |
| `store.gd` — facciata autoload, scelta del backend, `donate()` | completo |
| `revenuecat_android.gd` — lato Godot del ponte | completo |
| `revenuecat_web.gd` — lato Godot del ponte | completo (donazioni incluse) |
| plugin Android in Kotlin (`android/revenuecat_plugin/`) | sorgenti completi, **mai compilati** |
| ponte JavaScript (`web/aoa_billing.js`) | completo |
| `ui/store_panel.gd` — il pannello delle donazioni | completo |
| lato server: webhook + `public.donations` | completo (`db/migrations/0005_donations.sql`) |

Cosa manca davvero per incassare: compilare l'`.aar` (`android/README.md`), creare i prodotti su
RevenueCat e Google Play, e mettere la chiave pubblica in `catalog.json`.

## Come funziona una donazione

```
StorePanel → Store.donate(centesimi)     un pulsante = un taglio del catalogo
           → backend.purchase_product()  Google Play / Test Store
           → RevenueCat
           → webhook POST /revenuecat/webhook  → master → public.donations
StorePanel ← DONATIONS_REQUEST/DONATIONS_DATA ← master ← donation_summary()
```

Due vincoli che spiegano tutto il resto del disegno:

- **Su Google Play il prezzo di un prodotto è fisso**: non si può addebitare una cifra arbitraria.
  Per questo le donazioni sono a **importo fisso**, un pulsante per taglio. Un campo a cifra libera
  era la prima idea, ma prometteva ciò che il pagamento non può mantenere: qualunque cifra
  digitata sarebbe stata comunque riportata su un prodotto esistente. Meglio offrire solo ciò che
  si può davvero incassare.
- **La riga nel database la scrive il webhook, non il client.** La barra è pubblica: un totale
  sommato da chi paga sarebbe gonfiabile da chiunque sappia aprire un socket. Il client può solo
  *leggere* il totale, passando dal master come per tutto il resto.

Le donazioni sono **consumabili**: si ripetono e non concedono entitlement. Per questo esistono
due segnali separati — `purchase_completed` (sblocca qualcosa) e `product_purchase_completed` (non
sblocca niente) — e per questo il pannello non ha più "Ripristina acquisti": non c'è nulla di
permanente da ripristinare. Se un giorno gli entitlement tornassero in vendita, quel pulsante deve
tornare con loro: su Google Play è un requisito.

## Configurazione

1. Su **RevenueCat** creare i prodotti consumabili con gli id di `data/catalog.json` →
   `donations.tiers[].android`: `aoa_donate_99c`, `aoa_donate_199c`, `aoa_donate_299c`,
   `aoa_donate_499c`, `aoa_donate_999c`, `aoa_donate_2499c` — 0,99 / 1,99 / 2,99 / 4,99 / 9,99 /
   24,99 €. Gli id sono in **centesimi** col suffisso `c`: con prezzi come 1,99 e 2,99 un id in
   euro sarebbe ambiguo, e un errore così si scopre solo quando qualcuno paga la cifra sbagliata.
   Nessun entitlement: non concedono nulla.
   Aggiungere un importo significa una riga in `catalog.json` **e** un prodotto in ognuna delle
   due dashboard: è il costo che tiene corta la lista.
2. Chiave **pubblica** Android in `catalog.json` → `revenuecat.android_api_key`.
3. Webhook verso `https://<host>/revenuecat/webhook`, con header `Authorization` uguale a
   `REVENUECAT_WEBHOOK_SECRET` in `/etc/autochess/env` (vedi `deploy/env.example`).
4. Su **Google Play Console** gli stessi id, come prodotti in-app consumabili.

Si può fare tutto il punto 1–3 con la **Test Store** di RevenueCat prima di avere Google Play: è
il modo più rapido per verificare che la catena funzioni davvero.

## Sicurezza

- Le chiavi **pubbliche** dell'SDK in `catalog.json` vanno bene nel client: identificano l'app.
- La chiave **segreta** di RevenueCat non deve mai finire nel client, e infatti non serve: il
  server si autentica col webhook tramite segreto condiviso.
- `Store.has_entitlement()` resta una verifica **lato client**. Va bene per cosmetici e per aprire
  schermate; niente che influenzi una partita classificata può dipendere da essa. Oggi la domanda
  non si pone: `roster_mode: "shared"` tiene tutte le civiltà in gioco per tutti, e le donazioni
  non concedono vantaggi.

## Il ponte web

`revenuecat_web.gd` gestisce anche le donazioni, ma l'export HTML5 resta spento: manca la shell
HTML personalizzata descritta in `web/README.md`, e i price id `donations.tiers[].web` vanno
creati in RevenueCat Web Billing. Su Android non cambia niente.

## La questione delle civiltà

`catalog.json` ha ancora `roster_mode` (`shared` vs `owned`) e gli `entitlements` delle civiltà,
ma **nessuno di essi è più in vendita**: tutte le civiltà stanno in `free_origins`. Una civiltà
non gratuita e non acquistabile sarebbe per sempre non selezionabile — è il motivo per cui
togliere qualcosa dal negozio richiede sempre di controllare quella lista.
