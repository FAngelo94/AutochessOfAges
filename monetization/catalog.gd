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
		# I campi di testo (nomi/descrizioni entitlement, obiettivi delle
		# donazioni) seguono lo stesso schema di traduzione di GameData: un
		# catalog.<locale>.json affiancato, con fallback all'italiano.
		_data = GameData.load_localized(PATH)


## Ricarica da disco: usato da Profile.apply_locale() perché i testi seguono
## il locale corrente, come GameData.reload().
static func reload() -> void:
	_loaded = false
	_data.clear()
	ensure_loaded()


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


# --------------------------------------------------------------------------
# Donazioni (Crowdfunding Store)
# --------------------------------------------------------------------------
#
# Le donazioni non sono entitlement: non concedono nulla e si possono ripetere.
# Il gioco le conosce solo come importi in centesimi; il prodotto giusto per la
# piattaforma lo sceglie donation_product().

static func donations() -> Dictionary:
	return data().get("donations", {})


static func donation_goal_cents() -> int:
	return int(donations().get("goal_cents", 0))


static func donation_currency() -> String:
	return String(donations().get("currency", "EUR"))


## I tagli donabili, in centesimi, ordinati dal piu' piccolo. Sono anche i
## pulsanti del pannello: un taglio = un pulsante = un prodotto consumabile.
##
## Non esiste una cifra libera, e non e' una semplificazione della UI: su Google
## Play il prezzo di un prodotto e' fisso, quindi un importo arbitrario non
## sarebbe addebitabile. Meglio offrire solo cio' che si puo' davvero incassare
## che accettare una cifra e poi cambiarla.
static func donation_tiers() -> Array:
	var amounts: Array = []
	for tier in donations().get("tiers", []):
		if tier is Dictionary and int(tier.get("amount_cents", 0)) > 0:
			amounts.append(int(tier["amount_cents"]))
	amounts.sort()
	return amounts


## Identificativo di prodotto per un taglio, "" se il taglio non esiste.
static func donation_product(amount_cents: int, platform: String) -> String:
	for tier in donations().get("tiers", []):
		if tier is Dictionary and int(tier.get("amount_cents", -1)) == amount_cents:
			return String(tier.get(platform, ""))
	return ""


## Taglio corrispondente a un prodotto, 0 se il prodotto non è una donazione.
## Serve a riconoscere le risposte del negozio, che parlano di prodotti.
static func donation_amount_for_product(product_id: String, platform: String) -> int:
	for tier in donations().get("tiers", []):
		if tier is Dictionary and String(tier.get(platform, "")) == product_id:
			return int(tier.get("amount_cents", 0))
	return 0


## Tutti gli identificativi di prodotto delle donazioni per una piattaforma.
static func donation_product_ids(platform: String) -> PackedStringArray:
	var ids := PackedStringArray()
	for tier in donations().get("tiers", []):
		if tier is Dictionary:
			var product := String(tier.get(platform, ""))
			if not product.is_empty():
				ids.append(product)
	return ids


## Ciò che verrà implementato al raggiungimento dell'obiettivo, per la UI.
static func donation_goals() -> PackedStringArray:
	return PackedStringArray(donations().get("goals", []))


static func revenuecat_key(platform: String) -> String:
	return String(data().get("revenuecat", {}).get("%s_api_key" % platform, ""))


static func offering_id() -> String:
	return String(data().get("revenuecat", {}).get("offering_id", "default"))
