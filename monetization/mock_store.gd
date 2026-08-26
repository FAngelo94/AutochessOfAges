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


func backend_name() -> String:
	return "finto (sviluppo)"


func is_available() -> bool:
	return true


func initialize(_api_key: String, _user_id: String) -> void:
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
	products_loaded.emit(products)


func purchase(entitlement_id: String) -> void:
	if not Catalog.has_entitlement(entitlement_id):
		purchase_completed.emit(entitlement_id, false, "entitlement sconosciuto")
		return
	_owned[entitlement_id] = true
	_save()
	purchase_completed.emit(entitlement_id, true, "")
	entitlements_changed.emit(active_entitlements())


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
	_save()
	entitlements_changed.emit(active_entitlements())


func _load() -> void:
	_owned.clear()
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if parsed is Dictionary:
		_owned = parsed


func _save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("MockStore: impossibile scrivere %s" % SAVE_PATH)
		return
	file.store_string(JSON.stringify(_owned))
