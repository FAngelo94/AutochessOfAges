/*
 * Ponte tra RevenueCat Web Billing e il gioco, per l'export HTML5.
 *
 * Il lato Godot è monetization/revenuecat_web.gd, che cerca `window.AoaBilling`
 * e si aspetta esattamente questi metodi. I payload sono stringhe JSON con la
 * stessa forma del plugin Android: un solo contratto per due piattaforme.
 *
 * Nel browser non esiste Google Play: il pagamento passa da Stripe attraverso
 * una pagina ospitata da RevenueCat. Il gioco la apre e aspetta che gli
 * entitlement cambino — l'utente può anche pagare in un'altra scheda, quindi
 * non si può assumere che l'esito arrivi subito.
 */
(function () {
  "use strict";

  var purchases = null;
  var callbacks = { entitlements: null, purchase: null, products: null };

  function emit(which, payload) {
    var callback = callbacks[which];
    if (typeof callback === "function") {
      callback(JSON.stringify(payload));
    }
  }

  function activeEntitlements(customerInfo) {
    if (!customerInfo || !customerInfo.entitlements) return [];
    return Object.keys(customerInfo.entitlements.active || {});
  }

  function pushEntitlements(customerInfo) {
    emit("entitlements", { active: activeEntitlements(customerInfo) });
  }

  window.AoaBilling = {
    configure: function (apiKey, userId) {
      // L'SDK Web di RevenueCat va caricato dalla pagina prima di questo script.
      if (typeof Purchases === "undefined") {
        console.error("[AoaBilling] SDK RevenueCat non caricato");
        emit("entitlements", { active: [] });
        return;
      }
      try {
        purchases = Purchases.configure(apiKey, userId || Purchases.generateRevenueCatAnonymousAppUserId());
        purchases.getCustomerInfo().then(pushEntitlements).catch(function (error) {
          console.error("[AoaBilling] getCustomerInfo", error);
          emit("entitlements", { active: [] });
        });
      } catch (error) {
        console.error("[AoaBilling] configure", error);
        emit("entitlements", { active: [] });
      }
    },

    getProducts: function (csvProductIds) {
      if (!purchases) return emit("products", {});
      var wanted = (csvProductIds || "").split(",").map(function (id) { return id.trim(); });

      purchases.getOfferings().then(function (offerings) {
        var result = {};
        var current = offerings && offerings.current;
        var packages = (current && current.availablePackages) || [];
        packages.forEach(function (item) {
          var product = item.webBillingProduct || item.rcBillingProduct || item.product;
          if (!product || wanted.indexOf(product.identifier) === -1) return;
          result[product.identifier] = {
            price_string: (product.currentPrice && product.currentPrice.formattedPrice) || "",
            title: product.title || "",
            description: product.description || "",
          };
        });
        emit("products", result);
      }).catch(function (error) {
        console.error("[AoaBilling] getOfferings", error);
        emit("products", {});
      });
    },

    purchase: function (productId) {
      if (!purchases) {
        return emit("purchase", { product_id: productId, success: false, cancelled: false, error: "negozio non pronto" });
      }
      purchases.getOfferings().then(function (offerings) {
        var current = offerings && offerings.current;
        var packages = (current && current.availablePackages) || [];
        var match = null;
        packages.forEach(function (item) {
          var product = item.webBillingProduct || item.rcBillingProduct || item.product;
          if (product && product.identifier === productId) match = item;
        });
        if (!match) {
          return emit("purchase", { product_id: productId, success: false, cancelled: false, error: "prodotto non trovato" });
        }
        return purchases.purchase({ rcPackage: match }).then(function (result) {
          emit("purchase", { product_id: productId, success: true, cancelled: false, error: "" });
          pushEntitlements(result && result.customerInfo);
        });
      }).catch(function (error) {
        // Distinguere l'annullamento dall'errore vero: il gioco non deve
        // mostrare un messaggio d'errore a chi ha semplicemente cambiato idea.
        var cancelled = !!(error && (error.errorCode === "UserCancelledError" || error.code === "user_cancelled"));
        emit("purchase", {
          product_id: productId,
          success: false,
          cancelled: cancelled,
          error: cancelled ? "" : String((error && error.message) || error),
        });
      });
    },

    restore: function () {
      if (!purchases) return emit("entitlements", { active: [] });
      purchases.getCustomerInfo().then(pushEntitlements).catch(function () {
        emit("entitlements", { active: [] });
      });
    },

    onEntitlements: function (callback) { callbacks.entitlements = callback; },
    onPurchase: function (callback) { callbacks.purchase = callback; },
    onProducts: function (callback) { callbacks.products = callback; },
  };
})();
