package com.atuochess.revenuecat

import android.util.Log
import com.revenuecat.purchases.CustomerInfo
import com.revenuecat.purchases.PurchaseParams
import com.revenuecat.purchases.Purchases
import com.revenuecat.purchases.PurchasesConfiguration
import com.revenuecat.purchases.PurchasesError
import com.revenuecat.purchases.PurchasesErrorCode
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
            } catch (error: Exception) {
                Log.e(TAG, "configure fallita", error)
                emitEntitlements(emptyList())
            }
        }
    }

    /** Listino con i prezzi già localizzati dallo store. */
    @UsedByGodot
    fun getProducts(productIds: String) {
        val ids = productIds.split(",").map { it.trim() }.filter { it.isNotEmpty() }
        if (ids.isEmpty()) {
            emitSignal(SIGNAL_PRODUCTS, "{}")
            return
        }
        Purchases.sharedInstance.getProducts(
            ids,
            onError = { error ->
                Log.e(TAG, "getProducts: ${error.message}")
                emitSignal(SIGNAL_PRODUCTS, "{}")
            },
            onGetStoreProducts = { products -> emitProducts(products) },
        )
    }

    @UsedByGodot
    fun purchase(productId: String) {
        val currentActivity = activity
        if (currentActivity == null) {
            emitPurchase(productId, success = false, cancelled = false, error = "activity non disponibile")
            return
        }

        Purchases.sharedInstance.getProducts(
            listOf(productId),
            onError = { error ->
                emitPurchase(productId, success = false, cancelled = false, error = error.message)
            },
            onGetStoreProducts = { products ->
                val product = products.firstOrNull()
                if (product == null) {
                    emitPurchase(productId, success = false, cancelled = false, error = "prodotto non trovato")
                    return@getProducts
                }
                Purchases.sharedInstance.purchase(
                    PurchaseParams.Builder(currentActivity, product).build(),
                    onError = { error: PurchasesError, userCancelled: Boolean ->
                        // L'annullamento dell'utente NON è un errore da mostrare come tale:
                        // viaggia come flag separato e il lato Godot lo tratta a parte.
                        emitPurchase(
                            productId,
                            success = false,
                            cancelled = userCancelled || error.code == PurchasesErrorCode.PurchaseCancelledError,
                            error = if (userCancelled) "" else error.message,
                        )
                    },
                    onSuccess = { _: StoreTransaction?, customerInfo: CustomerInfo ->
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
        Purchases.sharedInstance.restorePurchases(
            onError = { error ->
                Log.e(TAG, "restorePurchases: ${error.message}")
                refreshEntitlements()
            },
            onSuccess = { customerInfo -> emitEntitlements(activeEntitlements(customerInfo)) },
        )
    }

    /** Rilegge lo stato dal server: utile dopo il login o al ritorno in primo piano. */
    @UsedByGodot
    fun refreshEntitlements() {
        Purchases.sharedInstance.getCustomerInfo(
            onError = { error ->
                Log.e(TAG, "getCustomerInfo: ${error.message}")
                emitEntitlements(emptyList())
            },
            onSuccess = { customerInfo -> emitEntitlements(activeEntitlements(customerInfo)) },
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
