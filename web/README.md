# Export web e ponte per gli acquisti

`aoa_billing.js` implementa `window.AoaBilling`, che `monetization/revenuecat_web.gd` cerca
all'avvio. Se non lo trova, il negozio resta disattivato e il gioco funziona lo stesso.

## Come agganciarlo all'export

Godot permette di sostituire la pagina HTML dell'export con una propria
(**Export → Web → Html → Custom HTML Shell**). Partendo da quella predefinita
(`godot/misc/dist/html/full-size.html`), servono due aggiunte dentro `<head>`:

```html
<!-- SDK Web di RevenueCat -->
<script src="https://cdn.jsdelivr.net/npm/@revenuecat/purchases-js/dist/Purchases.umd.js"></script>
<!-- Il ponte, copiato accanto alla pagina esportata -->
<script src="aoa_billing.js"></script>
```

L'ordine conta: `aoa_billing.js` usa `Purchases`, quindi va caricato dopo l'SDK.

Poi in `data/catalog.json` va compilato `revenuecat.web_api_key` con la chiave pubblica
di Web Billing, e i `products.*.web` devono corrispondere agli identificativi configurati
in RevenueCat.

## Verifica rapida

Nella console del browser, con il gioco aperto:

```js
typeof window.AoaBilling   // "object" se il ponte è agganciato
```

Se risponde `"undefined"`, `RevenueCatWeb.is_available()` restituisce false e nel pannello
del negozio compare "non disponibile su questa piattaforma".

## Nota sull'esito degli acquisti

Il pagamento avviene su una pagina ospitata da RevenueCat, che l'utente può completare
anche in un'altra scheda o dopo diversi minuti. Il ponte non presuppone che l'esito arrivi
subito: `onEntitlements` può scattare molto dopo `purchase`, e la UI deve limitarsi ad
aggiornarsi quando succede — cosa che `StorePanel` già fa, essendo agganciato al segnale
`entitlements_changed`.
