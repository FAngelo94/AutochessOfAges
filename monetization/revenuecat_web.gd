class_name RevenueCatWeb
extends StoreBackend

## Backend per l'export HTML5: RevenueCat Web Billing, guidato da
## JavaScriptBridge.
##
## È un percorso diverso da quello Android: nel browser non esiste Google Play,
## il pagamento passa da Stripe e l'acquisto avviene in una pagina ospitata da
## RevenueCat. Il gioco si limita ad aprirla e ad aspettare che gli entitlement
## cambino.
##
## La pagina HTML dell'export deve caricare l'SDK Web di RevenueCat e definire
## le funzioni ponte descritte in monetization/README.md.

var _active: PackedStringArray = PackedStringArray()
var _bridge: JavaScriptObject = null
var _callback_entitlements: JavaScriptObject = null
var _callback_purchase: JavaScriptObject = null
var _callback_products: JavaScriptObject = null


func backend_name() -> String:
	return "RevenueCat Web Billing"


func is_available() -> bool:
	if OS.get_name() != "Web":
		return false
	# La pagina ospite potrebbe non avere il ponte: senza, il gioco resta
	# giocabile e il negozio semplicemente non compare.
	return bool(JavaScriptBridge.eval("typeof window.AoaBilling !== 'undefined'", true))


func initialize(api_key: String, user_id: String) -> void:
	if not is_available():
		push_warning("RevenueCatWeb: window.AoaBilling non definito, negozio disattivato")
		return

	_bridge = JavaScriptBridge.get_interface("AoaBilling")

	# I riferimenti alle callback vanno tenuti vivi: se il GDScript li libera,
	# il JavaScript chiama un puntatore morto e la pagina si rompe.
	_callback_entitlements = JavaScriptBridge.create_callback(_on_entitlements)
	_callback_purchase = JavaScriptBridge.create_callback(_on_purchase)
	_callback_products = JavaScriptBridge.create_callback(_on_products)

	_bridge.onEntitlements(_callback_entitlements)
	_bridge.onPurchase(_callback_purchase)
	_bridge.onProducts(_callback_products)
	_bridge.configure(api_key, user_id)


func fetch_products(entitlement_ids: PackedStringArray) -> void:
	if _bridge == null:
		return
	var products := PackedStringArray()
	for entitlement_id in entitlement_ids:
		var product := Catalog.product_id(entitlement_id, "web")
		if not product.is_empty():
			products.append(product)
	_bridge.getProducts(",".join(products))


func purchase(entitlement_id: String) -> void:
	if _bridge == null:
		purchase_completed.emit(entitlement_id, false, "negozio non disponibile")
		return
	var product := Catalog.product_id(entitlement_id, "web")
	if product.is_empty():
		purchase_completed.emit(entitlement_id, false, "prodotto non configurato")
		return
	# Apre il flusso di pagamento ospitato. L'esito torna via callback: nel
	# browser l'utente può anche completare il pagamento in un'altra scheda.
	_bridge.purchase(product)


func restore_purchases() -> void:
	if _bridge != null:
		_bridge.restore()


func active_entitlements() -> PackedStringArray:
	return _active


func _on_entitlements(args: Array) -> void:
	var parsed = JSON.parse_string(String(args[0]) if args.size() > 0 else "")
	if parsed is Dictionary:
		_active = PackedStringArray(parsed.get("active", []))
		entitlements_changed.emit(_active)


func _on_purchase(args: Array) -> void:
	var parsed = JSON.parse_string(String(args[0]) if args.size() > 0 else "")
	if not (parsed is Dictionary):
		purchase_completed.emit("", false, "risposta non valida")
		return
	var product := String(parsed.get("product_id", ""))
	var entitlement_id := _entitlement_for_product(product)
	var success := bool(parsed.get("success", false))
	var reason := String(parsed.get("error", "cancelled" if parsed.get("cancelled", false) else ""))
	purchase_completed.emit(entitlement_id, success, reason)


func _on_products(args: Array) -> void:
	var parsed = JSON.parse_string(String(args[0]) if args.size() > 0 else "")
	if not (parsed is Dictionary):
		return
	var by_entitlement := {}
	for product in parsed.keys():
		var entitlement_id := _entitlement_for_product(String(product))
		if not entitlement_id.is_empty():
			by_entitlement[entitlement_id] = parsed[product]
	products_loaded.emit(by_entitlement)


func _entitlement_for_product(product: String) -> String:
	for entitlement_id in Catalog.entitlement_ids():
		if Catalog.product_id(entitlement_id, "web") == product:
			return entitlement_id
	return ""
