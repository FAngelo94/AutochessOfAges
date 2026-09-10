class_name MockStore
extends StoreBackend

## Negozio finto per lo sviluppo su desktop, dove nessuno store reale esiste.
##
## Gli acquisti riescono sempre e vengono salvati in user://mock_store.json,
## così si può provare l'intero flusso (paywall, sblocchi, ripristino) senza
## toccare Google Play. Non viene mai compilato nelle build di rilascio: vedi
## Store._select_backend().

const SAVE_PATH := "user://mock_store.json"

var _owned: Dictionary = {}
## Donazioni finte accumulate su questo dispositivo. Senza un server che
## risponda, è ciò che permette di vedere la barra del Crowdfunding Store
## avanzare davvero durante lo sviluppo, invece di guardare uno zero fisso.
var _donated_cents := 0
var _user_id := ""


func backend_name() -> String:
	return "finto (sviluppo)"


func is_available() -> bool:
	return true


func initialize(_api_key: String, user_id: String) -> void:
	_user_id = user_id
	_load()
	entitlements_changed.emit(active_entitlements())


func fetch_products(entitlement_ids: PackedStringArray) -> void:
	var products := {}
	for id in entitlement_ids:
		products[id] = {
			"price_string": "€ 4,99",
			"title": Catalog.entitlement_name(id),
			"description": Catalog.entitlement_description(id),
		}
	# Le donazioni restano sotto il proprio id di prodotto, come nei backend
	# reali: il pannello le cerca così.
	for amount in Catalog.donation_tiers():
		var product := Catalog.donation_product(int(amount), "android")
		if not product.is_empty():
			products[product] = {
				"price_string": "€ %d,00" % (int(amount) / 100),
				"title": "Donazione",
				"description": "",
			}
	products_loaded.emit(products)


func purchase(entitlement_id: String) -> void:
	if not Catalog.has_entitlement(entitlement_id):
		purchase_completed.emit(entitlement_id, false, "entitlement sconosciuto")
		return
	_owned[entitlement_id] = true
	_save()
	purchase_completed.emit(entitlement_id, true, "")
	entitlements_changed.emit(active_entitlements())


## Una donazione non concede niente e si può ripetere: qui riesce sempre, e
## l'importo si somma al totale finto locale.
func purchase_product(product_id: String) -> void:
	var amount := Catalog.donation_amount_for_product(product_id, "android")
	if amount <= 0:
		product_purchase_completed.emit(product_id, false, "prodotto sconosciuto")
		return
	_donated_cents += amount
	_save()
	product_purchase_completed.emit(product_id, true, "")


## Il negozio finto non ha account: tiene solo traccia di chi dice di essere,
## così i test possono verificare che il login arrivi fino a qui.
func identify(user_id: String) -> void:
	_user_id = user_id


func sign_out() -> void:
	_user_id = ""


func current_user_id() -> String:
	return _user_id


func donated_cents() -> int:
	return _donated_cents


func restore_purchases() -> void:
	_load()
	entitlements_changed.emit(active_entitlements())


func active_entitlements() -> PackedStringArray:
	var result := PackedStringArray()
	for id in _owned:
		if bool(_owned[id]):
			result.append(String(id))
	return result


## Comando di sviluppo: azzera gli acquisti finti per riprovare da capo.
func clear() -> void:
	_owned.clear()
	_donated_cents = 0
	_save()
	entitlements_changed.emit(active_entitlements())


## Legge anche i salvataggi nel formato precedente — un dizionario piatto di
## soli entitlement — perché chi ha già provato il negozio finto non deve
## ritrovarsi il file illeggibile dopo un aggiornamento.
func _load() -> void:
	_owned.clear()
	_donated_cents = 0
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if not (parsed is Dictionary):
		return
	if parsed.has("owned"):
		_owned = parsed.get("owned", {})
		_donated_cents = int(parsed.get("donated_cents", 0))
	else:
		_owned = parsed


func _save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("MockStore: impossibile scrivere %s" % SAVE_PATH)
		return
	file.store_string(JSON.stringify({"owned": _owned, "donated_cents": _donated_cents}))
