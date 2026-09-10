# Plugin Android per RevenueCat

Il pezzo che RevenueCat non fornisce per Godot. Il lato GDScript è
`monetization/revenuecat_android.gd`; qui c'è il lato nativo.

```
revenuecat_plugin/
  build.gradle
  libs/                 <- godot-lib.*.aar va messo qui a mano (non versionato)
  src/main/AndroidManifest.xml
  src/main/java/com/atuochess/revenuecat/RevenueCatGodotPlugin.kt
plugins/                <- cio' che Godot legge davvero: .gdap + .aar
settings.gradle         <- il progetto che include il modulo
build.gradle            <- versioni di AGP e Kotlin
gradle.properties
gradle/wrapper/
gradlew, gradlew.bat
```

Compilato e installato: `plugins/` contiene l'`.aar`, e l'SDK RevenueCat finisce davvero nell'APK
(verificabile cercando `Lcom/revenuecat/purchases/Purchases;` nei `classes*.dex`). Se un domani
l'`.aar` sparisse, `RevenueCatAndroid.is_available()` tornerebbe false, il negozio si nasconderebbe
e il gioco resterebbe interamente giocabile: nessuna funzione dipende dal negozio.

## Prerequisiti

- **JDK 17.** Non è una preferenza: AGP 8.5 non gira su JDK 22+. Se il JDK di sistema è più
  recente, si passa `JAVA_HOME` solo a questo comando invece di cambiare la configurazione globale.
- **Android SDK** con `platforms;android-34` e `build-tools;34.0.0`. Solo `cmdline-tools` non basta:
  si installano con `sdkmanager`.
- `godot-lib.template_release.aar` in `revenuecat_plugin/libs/` (non versionato, ~100 MB). **Non va
  scaricato**: è già dentro i template di export di Godot, in
  `%APPDATA%/Godot/export_templates/<versione>/android_source.zip`, sotto `libs/release/`. È
  `compileOnly`: serve a compilare ma non deve finire nell'`.aar`, perché la libreria Godot è già
  nell'applicazione e includerla due volte fa fallire il link.

## Compilazione

```sh
cd android
JAVA_HOME="/c/Program Files/Eclipse Adoptium/jdk-17...-hotspot" ./gradlew :revenuecat_plugin:assembleRelease
```

Poi copiare l'`.aar` prodotto in `android/plugins/`, accanto al `.gdap` che vive gia' li':

```sh
cp revenuecat_plugin/build/outputs/aar/RevenueCatGodot.release.aar plugins/
```

Il `.gdap` sta **solo** in `android/plugins/`, e non altrove: quando ne esistevano due copie,
aggiornare la versione dell'SDK in quella sbagliata lasciava Godot a impacchettare la vecchia
senza dire niente. La versione dichiarata li' e quella in `revenuecat_plugin/build.gradle` devono
restare identiche.

**Attenzione al `.gdap`:** dichiara solo `RevenueCatGodot.release.aar`. Un export *debug*
cercherebbe un file che non esiste, quindi si esporta sempre in **release**, anche durante i test
su dispositivo.

## Export

Gia' configurato in `export_presets.cfg`: `gradle_build/use_gradle_build=true` (senza, **nessun
plugin viene incluso nell'APK** e tutto il resto e' inutile), min sdk 24, target sdk 34 e
`plugins/RevenueCatGodot=true`.

Il modello di build Android (`android/build/`, ignorato da git) si installa dall'editor
(**Progetto → Installa modello di build Android**) oppure da riga di comando:

```sh
godot --headless --path . --install-android-build-template --export-debug "Android" build/android/app.apk
```

Richiede che in **Impostazioni Editor → Export → Android** siano corretti `android_sdk_path` e
`java_sdk_path` (quest'ultimo al **JDK 17**).

## Configurazione dei prodotti

1. Su **RevenueCat** creare i prodotti consumabili delle donazioni con gli id di
   `data/catalog.json` → `donations.tiers[].android` (`aoa_donate_99c` … `aoa_donate_2499c`,
   cioè 0,99 / 1,99 / 2,99 / 4,99 / 9,99 / 24,99 €; gli id sono in centesimi perché con prezzi
   come 1,99 e 2,99 un id in euro sarebbe ambiguo).
   Per provare senza Google Play si usa la **Test Store**, che pero' richiede l'SDK Android
   **>= 9.9.0** — e' la ragione per cui la dipendenza sta alla 10.20.0 e non alla 8.10.0.
   La chiave della Test Store non deve MAI finire in una build pubblicata.
2. Su **Google Play Console** creare gli stessi id come prodotti in-app **consumabili**.
3. Chiave **pubblica** Android in `catalog.json` → `revenuecat.android_api_key`. La chiave segreta
   non deve mai stare nel client.
4. Webhook di RevenueCat verso `https://<host>/revenuecat/webhook` (vedi `deploy/Caddyfile` e
   `REVENUECAT_WEBHOOK_SECRET` in `deploy/env.example`): è l'unico modo in cui una donazione
   finisce nel database.

Gli acquisti reali funzionano solo da un'app installata **tramite Play** e firmata con la stessa
chiave: un APK sideloaded non li vede. Per provare prima di avere tutto questo, si usa la **Test
Store** di RevenueCat.

## Contratto tra Kotlin e GDScript

Godot risolve le chiamate ai singleton a runtime: se un nome cambia da un lato solo, non c'è
errore di compilazione e l'integrazione smette di funzionare **in silenzio**. Va provata su
dispositivo, non solo in headless.

| Metodo Kotlin | Chiamato da |
|---|---|
| `configure(apiKey, userId)` | `RevenueCatAndroid.initialize()` |
| `logIn(userId)` / `logOut()` | `identify()` / `sign_out()`, al login e al logout |
| `getProducts(csvProductIds)` | `fetch_products()` — entitlement **e** tagli di donazione |
| `purchase(productId)` | `purchase()` (entitlement) e `purchase_product()` (donazioni) |
| `restorePurchases()` | `restore_purchases()` |
| `refreshEntitlements()` | (utile al ritorno in primo piano) |

| Segnale | Payload JSON |
|---|---|
| `on_entitlements` | `{"active": ["season_pass", …]}` |
| `on_purchase` | `{"product_id", "success", "cancelled", "error", "active_entitlements"}` |
| `on_products` | `{"<product_id>": {"price_string", "title", "description"}}` |

`on_purchase` serve a entrambi i casi: il lato GDScript instrada l'esito guardando se il prodotto
corrisponde a un entitlement (allora sblocca) o no (allora è una donazione).

`logIn` non è un dettaglio: `configure` parte all'avvio, quando il giocatore non ha ancora fatto
il login, e fino a quel momento RevenueCat conosce solo un id anonimo di dispositivo. Senza
`logIn`, gli acquisti non seguono il giocatore da un telefono all'altro e una donazione arriva al
webhook con un `app_user_id` che non corrisponde a nessun profilo.

## Prova senza dispositivo

Su desktop il gioco usa il negozio finto (`MockStore`) e l'intero flusso — donazione, barra che
avanza, ripetibilità — è provabile subito: `godot --path .`, poi il pulsante
**Negozio**. `tests/menu_smoke.gd` esercita lo stesso pannello senza interfaccia grafica.
