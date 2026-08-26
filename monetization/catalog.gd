class_name Catalog
extends RefCounted

## Lettura di data/catalog.json: entitlement, prodotti per piattaforma,
## contenuti gratuiti.
##
## Il gioco ragiona sempre per entitlement ("civ_gaul"), mai per prodotto
## ("aoa_civ_gaul"): gli identificativi di prodotto cambiano tra store, gli
## entitlement no.

const PATH := "res://data/catalog.json"

static var _data: Dictionary = {}
static var _loaded := false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var text := FileAccess.get_file_as_string(PATH)
	if text.is_empty():
		push_error("Catalog: impossibile leggere %s" % PATH)
		return
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		_data = parsed


static func data() -> Dictionary:
	ensure_loaded()
	return _data


static func entitlements() -> Dictionary:
	return data().get("entitlements", {})


static func entitlement_ids() -> PackedStringArray:
	var ids := PackedStringArray(entitlements().keys())
	ids.sort()
	return ids


static func has_entitlement(entitlement_id: String) -> bool:
	return entitlements().has(entitlement_id)


static func entitlement_name(entitlement_id: String) -> String:
	return entitlements().get(entitlement_id, {}).get("name", entitlement_id)


static func entitlement_description(entitlement_id: String) -> String:
	return entitlements().get(entitlement_id, {}).get("description", "")


static func is_subscription(entitlement_id: String) -> bool:
	return entitlements().get(entitlement_id, {}).get("type", "") == "subscription"


## Identificativo di prodotto per la piattaforma corrente.
static func product_id(entitlement_id: String, platform: String) -> String:
	return data().get("products", {}).get(entitlement_id, {}).get(platform, "")


## Diritti concessi da un entitlement, es. ["origin:gaul"].
static func grants(entitlement_id: String) -> PackedStringArray:
	return PackedStringArray(entitlements().get(entitlement_id, {}).get("grants", []))


## Entitlement che sblocca una civiltà, o "" se la civiltà è gratuita.
static func entitlement_for_origin(origin_id: String) -> String:
	if free_origins().has(origin_id):
		return ""
	var wanted := "origin:%s" % origin_id
	for id in entitlement_ids():
		if grants(id).has(wanted):
			return id
	return ""


static func free_origins() -> PackedStringArray:
	return PackedStringArray(data().get("free_origins", []))


## 'shared' = la lobby sceglie il set di civiltà per tutti; 'owned' = si gioca
## solo con ciò che si possiede. Vedi la nota in catalog.json.
static func roster_mode() -> String:
	return String(data().get("roster_mode", "shared"))


static func revenuecat_key(platform: String) -> String:
	return String(data().get("revenuecat", {}).get("%s_api_key" % platform, ""))


static func offering_id() -> String:
	return String(data().get("revenuecat", {}).get("offering_id", "default"))
