# Plugin Android per RevenueCat

Il pezzo che RevenueCat non fornisce per Godot. Il lato GDScript è
`monetization/revenuecat_android.gd`; qui c'è il lato nativo.

```
revenuecat_plugin/
  build.gradle
  src/main/AndroidManifest.xml
  src/main/java/com/atuochess/revenuecat/RevenueCatGodotPlugin.kt
RevenueCatGodot.gdap
```

## Compilazione

Non è compilabile senza Android SDK: i sorgenti sono completi, l'`.aar` va prodotto una volta.

1. **`godot-lib`**: scarica dalla pagina delle release di Godot 4.7 il pacchetto Android
   (`godot-lib.4.7.stable.template_release.aar`) e mettilo in `revenuecat_plugin/libs/`.
   È dichiarato `compileOnly`: serve a compilare, ma non deve finire dentro l'`.aar` —
   è già nell'applicazione, e includerlo due volte fa fallire il link.
2. Crea un progetto Gradle che includa `revenuecat_plugin` come modulo (o aprilo in
   Android Studio) e lancia:
   ```sh
   ./gradlew :revenuecat_plugin:assembleRelease
   ```
3. Copia in `android/plugins/` del progetto Godot:
   - `RevenueCatGodot.release.aar` (da `build/outputs/aar/`)
   - `RevenueCatGodot.gdap`
4. In Godot: **Progetto → Installa modello di build Android**, poi nelle impostazioni di
   export Android attiva **Use Gradle Build** e spunta il plugin `RevenueCatGodot`.

## Configurazione

1. Su **Google Play Console** crea i prodotti con gli identificativi che stanno in
   `data/catalog.json` sotto `products.*.android`:
   `aoa_season_pass_monthly`, `aoa_civ_gaul`, `aoa_civ_teuton`, `aoa_skin_roman_gold`.
2. Su **RevenueCat** collega l'app Play, importa i prodotti e crea gli **entitlement** con
   gli stessi nomi delle chiavi di `entitlements` in `catalog.json`:
   `season_pass`, `civ_gaul`, `civ_teuton`, `cosmetic_pack_legion`.
   I nomi devono coincidere: il gioco ragiona per entitlement e non conosce i prodotti.
3. Metti la chiave **pubblica** Android in `catalog.json` → `revenuecat.android_api_key`.
   La chiave segreta non deve mai stare nel client.

## Contratto tra Kotlin e GDScript

Godot risolve le chiamate ai singleton a runtime: se un nome cambia da un lato solo,
non c'è errore di compilazione e l'integrazione smette di funzionare in silenzio.

| Metodo Kotlin | Chiamato da |
|---|---|
| `configure(apiKey, userId)` | `RevenueCatAndroid.initialize()` |
| `getProducts(csvProductIds)` | `fetch_products()` |
| `purchase(productId)` | `purchase()` |
| `restorePurchases()` | `restore_purchases()` |
| `refreshEntitlements()` | (utile al ritorno in primo piano) |

| Segnale | Payload JSON |
|---|---|
| `on_entitlements` | `{"active": ["season_pass", …]}` |
| `on_purchase` | `{"product_id", "success", "cancelled", "error", "active_entitlements"}` |
| `on_products` | `{"<product_id>": {"price_string", "title", "description"}}` |

## Prova senza dispositivo

Su desktop il gioco usa il negozio finto (`MockStore`) e l'intero flusso — acquisto,
sblocco, ripristino, riavvio — è provabile subito: `godot --path .`, poi il pulsante
**Negozio**. `tests/ui_smoke.gd` esercita lo stesso percorso senza interfaccia grafica.
