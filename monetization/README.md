# Monetizzazione — stato e lavoro rimanente

RevenueCat **non ha un SDK per Godot**. Supporta iOS, Android nativo, Unity, Flutter,
React Native, Cordova, KMP e Web Billing. Per usarlo da Godot serve un ponte, ed è per
questo che lo strato è diviso in un'interfaccia e più backend.

## Cosa è già pronto

| Componente | Stato |
|---|---|
| `store_backend.gd` — interfaccia comune | completo |
| `mock_store.gd` — negozio finto per lo sviluppo | completo e funzionante |
| `catalog.gd` + `data/catalog.json` — entitlement e prodotti | completo |
| `store.gd` — facciata autoload, scelta del backend, sblocchi | completo |
| `revenuecat_android.gd` — lato Godot del ponte | completo |
| `revenuecat_web.gd` — lato Godot del ponte | completo |
| **plugin Android in Kotlin** | **da scrivere** (vedi sotto) |
| **ponte JavaScript per l'export web** | **da scrivere** (vedi sotto) |
| paywall / UI del negozio | da fare |

Su desktop il gioco usa il negozio finto e l'intero flusso è provabile subito. Su Android e
Web, finché i due ponti non esistono, `is_available()` risponde false, il negozio non compare
e **il gioco resta interamente giocabile** con i contenuti gratuiti. È un vincolo di progetto:
nessuna funzione di gioco dipende dal negozio.

## Plugin Android (Kotlin) — da fare

Un plugin Godot per Android che avvolge `com.revenuecat.purchases:purchases`. Deve registrarsi
come singleton `RevenueCatGodot` ed esporre:

```kotlin
fun configure(apiKey: String, userId: String)
fun getProducts(productIds: String)   // separati da virgola
fun purchase(productId: String)
fun restorePurchases()

// segnali, tutti con un unico argomento String contenente JSON
signal on_entitlements(json)  // {"active": ["season_pass", ...]}
signal on_purchase(json)      // {"product_id": "...", "success": true, "cancelled": false, "error": "", "active_entitlements": [...]}
signal on_products(json)      // {"aoa_civ_gaul": {"price_string": "€ 3,99", "title": "...", "description": "..."}}
```

Passi:

1. Progetto libreria Android, dipendenza `com.revenuecat.purchases:purchases:<versione>`.
2. Classe che estende `GodotPlugin`, con `getPluginSignals()` e `getPluginName() = "RevenueCatGodot"`.
3. Build in `.aar`, copiato in `android/plugins/` insieme al `.gdap`.
4. Export template Android personalizzato attivo nelle impostazioni di export.
5. In `catalog.json` compilare `revenuecat.android_api_key` con la chiave **pubblica** dell'app.

I nomi degli entitlement configurati nella dashboard RevenueCat devono coincidere con le chiavi
di `entitlements` in `catalog.json` (`season_pass`, `civ_gaul`, …); gli id di prodotto devono
coincidere con quelli in `products.*.android` e con quelli creati su Google Play Console.

## Ponte web (JavaScript) — da fare

Nella pagina HTML dell'export, caricare l'SDK Web di RevenueCat e definire `window.AoaBilling`:

```js
window.AoaBilling = {
  configure(apiKey, userId) { /* Purchases.configure(...) */ },
  getProducts(csvProductIds) { /* -> onProducts(JSON) */ },
  purchase(productId)        { /* apre il flusso, poi -> onPurchase(JSON) */ },
  restore()                  { /* -> onEntitlements(JSON) */ },
  onEntitlements(cb) { this._ent = cb },
  onPurchase(cb)     { this._pur = cb },
  onProducts(cb)     { this._pro = cb },
};
```

I payload sono gli stessi del lato Android. Serve un template HTML di export personalizzato.

## Sicurezza

- Le chiavi **pubbliche** dell'SDK in `catalog.json` vanno bene nel client: identificano l'app.
- La chiave **segreta** di RevenueCat (v1 secret) non deve mai finire nel client. Serve solo a
  un eventuale server per la REST API.
- `Store.has_entitlement()` è una verifica **lato client**: va benissimo per cosmetici e per
  aprire schermate. Quando arriverà il multiplayer, qualsiasi cosa che influenzi una partita
  classificata va verificata dal server, che interroga la REST API di RevenueCat. Un client
  può sempre mentire su ciò che possiede.

## La questione delle civiltà a pagamento

`catalog.json` ha `roster_mode`:

- **`shared`** (predefinito) — tutte le civiltà sono in gioco per tutti, il pool condiviso resta
  identico per ogni giocatore. L'acquisto sblocca la possibilità di *sceglierle* in singolo e di
  proporle in lobby. Il competitivo resta equo.
- **`owned`** — si gioca solo con le civiltà possedute, che entrano nel proprio pool. Più facile
  da vendere, ma due giocatori non stanno più giocando alla stessa partita.

La scelta è di design, non tecnica: cambiare una riga in `catalog.json` cambia modello.
