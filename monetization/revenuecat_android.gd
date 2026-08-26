class_name RevenueCatAndroid
extends StoreBackend

## Backend Android: ponte verso l'SDK RevenueCat per Kotlin.
##
## RevenueCat non pubblica un SDK per Godot. Questo script parla con un plugin
## Android (vedi monetization/README.md) che espone l'SDK come singleton
## Godot. Se il plugin non è installato, is_available() risponde false e il
## gioco resta giocabile senza negozio: nessun contenuto a pagamento è
## necessario per giocare.
##
## Nomi dei metodi e dei segnali attesi dal plugin (lato Kotlin):
##   configure(apiKey: String, userId: String)
##   getProducts(productIds: String)   -- lista separata da virgole
##   purchase(productId: String)
##   restorePurchases()
##   segnali: on_entitlements(json), on_purchase(json), on_products(json)

const SINGLETON_NAME := "RevenueCatGodot"

var _plugin: Object = null
var _active: PackedStringArray = PackedStringArray()
## product_id -> entitlement_id, per tradurre all'indietro le risposte del plugin.
var _product_to_entitlement: Dictionary = {}


func backend_name() -> String:
	return "RevenueCat (Android)"


func is_available() -> bool:
	return OS.get_name() == "Android" and Engine.has_singleton(SINGLETON_NAME)


func initialize(api_key: String, user_id: String) -> void:
	if not is_available():
		push_warning("RevenueCatAndroid: plugin '%s' non trovato, negozio disattivato" % SINGLETON_NAME)
		return
	if api_key.is_empty():
		push_error("RevenueCatAndroid: manca android_api_key in catalog.json")
		return

	_plugin = Engine.get_singleton(SINGLETON_NAME)
	_build_product_map()

	_connect_if_present("on_entitlements", _on_entitlements)
	_connect_if_present("on_purchase", _on_purchase)
	_connect_if_present("on_products", _on_products)

	_plugin.configure(api_key, user_id)


## Il plugin potrebbe essere una versione più vecchia: collegarsi a un segnale
## inesistente farebbe crashare l'avvio, cosa inaccettabile per uno strato che
## deve poter mancare del tutto.
func _connect_if_present(signal_name: String, callable: Callable) -> void:
	if _plugin.has_signal(signal_name):
		_plugin.connect(signal_name, callable)
	else:
		push_warning("RevenueCatAndroid: il plugin non espone il segnale '%s'" % signal_name)


func _build_product_map() -> void:
	_product_to_entitlement.clear()
	for entitlement_id in Catalog.entitlement_ids():
		var product := Catalog.product_id(entitlement_id, "android")
		if not product.is_empty():
			_product_to_entitlement[product] = entitlement_id


func fetch_products(entitlement_ids: PackedStringArray) -> void:
	if _plugin == null:
		return
	var products := PackedStringArray()
	for entitlement_id in entitlement_ids:
		var product := Catalog.product_id(entitlement_id, "android")
		if not product.is_empty():
			products.append(product)
	_plugin.getProducts(",".join(products))


func purchase(entitlement_id: String) -> void:
	if _plugin == null:
		purchase_completed.emit(entitlement_id, false, "negozio non disponibile")
		return
	var product := Catalog.product_id(entitlement_id, "android")
	if product.is_empty():
		purchase_completed.emit(entitlement_id, false, "prodotto non configurato")
		return
	_plugin.purchase(product)


func restore_purchases() -> void:
	if _plugin != null:
		_plugin.restorePurchases()


func active_entitlements() -> PackedStringArray:
	return _active


# --------------------------------------------------------------------------
# Risposte dal plugin
# --------------------------------------------------------------------------

## Il plugin manda gli identificativi degli entitlement come li conosce
## RevenueCat: vanno usati gli stessi nomi che stanno in catalog.json.
func _on_entitlements(payload: String) -> void:
	var parsed = JSON.parse_string(payload)
	if not (parsed is Dictionary):
		push_error("RevenueCatAndroid: risposta entitlements non valida")
		return
	_active = PackedStringArray(parsed.get("active", []))
	entitlements_changed.emit(_active)


func _on_purchase(payload: String) -> void:
	var parsed = JSON.parse_string(payload)
	if not (parsed is Dictionary):
		purchase_completed.emit("", false, "risposta non valida")
		return

	var product := String(parsed.get("product_id", ""))
	var entitlement_id := String(_product_to_entitlement.get(product, ""))
	var success := bool(parsed.get("success", false))
	# L'annullamento dell'utente non è un errore: la UI non deve mostrarlo
	# come tale, quindi arriva con una ragione riconoscibile.
	var reason := String(parsed.get("error", "cancelled" if parsed.get("cancelled", false) else ""))

	purchase_completed.emit(entitlement_id, success, reason)
	if success:
		_active = PackedStringArray(parsed.get("active_entitlements", _active))
		entitlements_changed.emit(_active)


func _on_products(payload: String) -> void:
	var parsed = JSON.parse_string(payload)
	if not (parsed is Dictionary):
		return
	# Riporta le chiavi da product_id a entitlement_id: al gioco i prodotti
	# non interessano.
	var by_entitlement := {}
	for product in parsed.keys():
		var entitlement_id := String(_product_to_entitlement.get(product, ""))
		if not entitlement_id.is_empty():
			by_entitlement[entitlement_id] = parsed[product]
	products_loaded.emit(by_entitlement)
