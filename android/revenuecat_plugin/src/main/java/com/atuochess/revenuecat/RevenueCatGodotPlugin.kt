package com.atuochess.revenuecat

import android.util.Log
import com.revenuecat.purchases.CustomerInfo
import com.revenuecat.purchases.PurchaseParams
import com.revenuecat.purchases.Purchases
import com.revenuecat.purchases.PurchasesConfiguration
import com.revenuecat.purchases.PurchasesError
import com.revenuecat.purchases.PurchasesErrorCode
// Le API a callback dell'SDK sono estensioni top-level, non metodi di Purchases:
// vanno importate esplicitamente o il compilatore vede solo le overload che
// prendono un oggetto Callback.
import com.revenuecat.purchases.getCustomerInfoWith
import com.revenuecat.purchases.getProductsWith
import com.revenuecat.purchases.logInWith
import com.revenuecat.purchases.logOutWith
import com.revenuecat.purchases.purchaseWith
import com.revenuecat.purchases.restorePurchasesWith
import com.revenuecat.purchases.models.StoreProduct
import com.revenuecat.purchases.models.StoreTransaction
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject

/**
 * Ponte tra l'SDK Android di RevenueCat e GDScript.
 *
 * RevenueCat non pubblica un SDK per Godot: questo plugin è il pezzo mancante.
 * Il lato Godot è `monetization/revenuecat_android.gd`, che si aspetta esattamente
 * i metodi e i segnali dichiarati qui — cambiare un nome da un lato senza cambiarlo
 * dall'altro rompe l'integrazione in silenzio, perché Godot risolve le chiamate ai
 * singleton a runtime.
 *
 * Tutti i payload viaggiano come stringhe JSON: è l'unico tipo che attraversa il
 * confine JNI senza sorprese, e mantiene il contratto identico a quello del ponte web.
 */
class RevenueCatGodotPlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val TAG = "RevenueCatGodot"

        private const val SIGNAL_ENTITLEMENTS = "on_entitlements"
        private const val SIGNAL_PURCHASE = "on_purchase"
        private const val SIGNAL_PRODUCTS = "on_products"
    }

    /**
     * Richiesta di listino arrivata prima che l'SDK fosse pronto.
     *
     * `configure` non e' istantanea: gira su runOnUiThread e ritorna subito. Il
     * lato Godot pero' chiama initialize() e fetch_products() nello stesso
     * frame (Store._ready), quindi getProducts arriva quasi sempre PRIMA che
     * Purchases sia configurato — e Purchases.sharedInstance su un SDK non
     * configurato solleva un'eccezione. La richiesta si mette da parte e si
     * rigioca appena la configurazione e' finita.
     */
    @Volatile
    private var pendingProductIds: String? = null

    override fun getPluginName(): String = "RevenueCatGodot"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo(SIGNAL_ENTITLEMENTS, String::class.java),
        SignalInfo(SIGNAL_PURCHASE, String::class.java),
        SignalInfo(SIGNAL_PRODUCTS, String::class.java),
    )

    /**
     * Inizializza l'SDK. `userId` deve essere stabile per il giocatore, altrimenti
     * gli acquisti non lo seguono da un dispositivo all'altro.
     */
    @UsedByGodot
    fun configure(apiKey: String, userId: String) {
        runOnUiThread {
            try {
                val builder = PurchasesConfiguration.Builder(activity!!.applicationContext, apiKey)
                if (userId.isNotEmpty()) {
                    builder.appUserID(userId)
                }
                Purchases.configure(builder.build())
                refreshEntitlements()
                pendingProductIds?.let { ids ->
                    pendingProductIds = null
                    getProducts(ids)
                }
            } catch (error: Exception) {
                Log.e(TAG, "configure fallita", error)
                emitEntitlements(emptyList())
            }
        }
    }

    /**
     * Associa gli acquisti a un account, dopo il login.
     *
     * `configure` parte all'avvio del gioco, quando l'utente non ha ancora fatto il
     * login: fino a qui RevenueCat conosce solo un id anonimo di dispositivo. Senza
     * questa chiamata gli acquisti non seguono il giocatore da un telefono all'altro,
     * e una donazione arriva al webhook con un id che non corrisponde a nessun
     * profilo — quindi non è attribuibile a nessuno.
     */
    @UsedByGodot
    fun logIn(userId: String) {
        if (userId.isEmpty() || !Purchases.isConfigured) {
            return
        }
        Purchases.sharedInstance.logInWith(
            userId,
            { error: PurchasesError ->
                Log.e(TAG, "logIn: ${error.message}")
                refreshEntitlements()
            },
            { customerInfo: CustomerInfo, _: Boolean -> emitEntitlements(activeEntitlements(customerInfo)) },
        )
    }

    /** Torna all'utente anonimo, al logout. */
    @UsedByGodot
    fun logOut() {
        if (!Purchases.isConfigured) {
            return
        }
        Purchases.sharedInstance.logOutWith(
            { error: PurchasesError -> Log.e(TAG, "logOut: ${error.message}") },
            { customerInfo: CustomerInfo -> emitEntitlements(activeEntitlements(customerInfo)) },
        )
    }

    /** Listino con i prezzi già localizzati dallo store. */
    @UsedByGodot
    fun getProducts(productIds: String) {
        val ids = productIds.split(",").map { it.trim() }.filter { it.isNotEmpty() }
        if (ids.isEmpty()) {
            emitSignal(SIGNAL_PRODUCTS, "{}")
            return
        }
        if (!Purchases.isConfigured) {
            pendingProductIds = productIds
            return
        }
        Purchases.sharedInstance.getProductsWith(
            ids,
            { error: PurchasesError ->
                Log.e(TAG, "getProducts: ${error.message}")
                emitSignal(SIGNAL_PRODUCTS, "{}")
            },
            { products: List<StoreProduct> -> emitProducts(products) },
        )
    }

    @UsedByGodot
    fun purchase(productId: String) {
        if (!Purchases.isConfigured) {
            emitPurchase(productId, success = false, cancelled = false, error = "negozio non pronto")
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            emitPurchase(productId, success = false, cancelled = false, error = "activity non disponibile")
            return
        }

        Purchases.sharedInstance.getProductsWith(
            listOf(productId),
            { error: PurchasesError ->
                emitPurchase(productId, success = false, cancelled = false, error = error.message)
            },
            { products: List<StoreProduct> ->
                val product = products.firstOrNull()
                if (product == null) {
                    emitPurchase(productId, success = false, cancelled = false, error = "prodotto non trovato")
                    return@getProductsWith
                }
                Purchases.sharedInstance.purchaseWith(
                    PurchaseParams.Builder(currentActivity, product).build(),
                    { error: PurchasesError, userCancelled: Boolean ->
                        // L'annullamento dell'utente NON è un errore da mostrare come tale:
                        // viaggia come flag separato e il lato Godot lo tratta a parte.
                        emitPurchase(
                            productId,
                            success = false,
                            cancelled = userCancelled || error.code == PurchasesErrorCode.PurchaseCancelledError,
                            error = if (userCancelled) "" else error.message,
                        )
                    },
                    { _: StoreTransaction?, customerInfo: CustomerInfo ->
                        emitPurchase(productId, success = true, cancelled = false, error = "", customerInfo = customerInfo)
                    },
                )
            },
        )
    }

    /**
     * Obbligatorio su Google Play: senza, chi reinstalla perde ciò che ha pagato.
     */
    @UsedByGodot
    fun restorePurchases() {
        if (!Purchases.isConfigured) {
            return
        }
        Purchases.sharedInstance.restorePurchasesWith(
            { error: PurchasesError ->
                Log.e(TAG, "restorePurchases: ${error.message}")
                refreshEntitlements()
            },
            { customerInfo: CustomerInfo -> emitEntitlements(activeEntitlements(customerInfo)) },
        )
    }

    /** Rilegge lo stato dal server: utile dopo il login o al ritorno in primo piano. */
    @UsedByGodot
    fun refreshEntitlements() {
        if (!Purchases.isConfigured) {
            return
        }
        Purchases.sharedInstance.getCustomerInfoWith(
            { error: PurchasesError ->
                Log.e(TAG, "getCustomerInfo: ${error.message}")
                emitEntitlements(emptyList())
            },
            { customerInfo: CustomerInfo -> emitEntitlements(activeEntitlements(customerInfo)) },
        )
    }

    private fun activeEntitlements(customerInfo: CustomerInfo): List<String> =
        customerInfo.entitlements.active.keys.toList()

    private fun emitEntitlements(entitlements: List<String>) {
        val payload = JSONObject().put("active", JSONArray(entitlements))
        emitSignal(SIGNAL_ENTITLEMENTS, payload.toString())
    }

    private fun emitProducts(products: List<StoreProduct>) {
        val payload = JSONObject()
        for (product in products) {
            payload.put(
                product.id,
                JSONObject()
                    .put("price_string", product.price.formatted)
                    .put("title", product.title)
                    .put("description", product.description),
            )
        }
        emitSignal(SIGNAL_PRODUCTS, payload.toString())
    }

    private fun emitPurchase(
        productId: String,
        success: Boolean,
        cancelled: Boolean,
        error: String,
        customerInfo: CustomerInfo? = null,
    ) {
        val payload = JSONObject()
            .put("product_id", productId)
            .put("success", success)
            .put("cancelled", cancelled)
            .put("error", error)
        if (customerInfo != null) {
            payload.put("active_entitlements", JSONArray(activeEntitlements(customerInfo)))
        }
        emitSignal(SIGNAL_PURCHASE, payload.toString())

        // Dopo un acquisto riuscito lo stato è cambiato: va comunicato anche a chi
        // ascolta solo gli entitlement, non i singoli acquisti.
        if (success && customerInfo != null) {
            emitEntitlements(activeEntitlements(customerInfo))
        }
    }
}
