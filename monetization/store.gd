extends Node

## Facciata del negozio: l'unico punto che il resto del gioco conosce.
## Registrato come autoload "Store" (vedi project.godot).
##
## Sceglie da sé il backend giusto per la piattaforma e tiene la lista degli
## entitlement attivi. Se nessun backend è disponibile — desktop di sviluppo,
## plugin mancante, pagina web senza ponte — il gioco continua a funzionare
## con i soli contenuti gratuiti: nessuna funzione di gioco dipende dal
## negozio, e questo è un vincolo di progetto, non un caso fortunato.

signal entitlements_changed
signal purchase_completed(entitlement_id: String, success: bool, reason: String)
signal products_loaded(products: Dictionary)

var backend: StoreBackend
var products: Dictionary = {}

var _active: Dictionary = {}


func _ready() -> void:
	Catalog.ensure_loaded()
	backend = _select_backend()
	print("[Store] backend: %s" % backend.backend_name())

	backend.entitlements_changed.connect(_on_entitlements_changed)
	backend.purchase_completed.connect(_on_purchase_completed)
	backend.products_loaded.connect(_on_products_loaded)

	var platform := platform_key()
	backend.initialize(Catalog.revenuecat_key(platform), user_id())
	backend.fetch_products(Catalog.entitlement_ids())


## Il primo backend disponibile vince. Il negozio finto resta in fondo e non
## viene mai scelto su una piattaforma reale.
func _select_backend() -> StoreBackend:
	var candidates: Array[StoreBackend] = [RevenueCatAndroid.new(), RevenueCatWeb.new()]
	for candidate in candidates:
		if candidate.is_available():
			return candidate
	if OS.is_debug_build():
		return MockStore.new()
	return StoreBackend.new()


func platform_key() -> String:
	return "android" if OS.get_name() == "Android" else "web"


## Identificativo stabile dell'utente. Per ora è locale al dispositivo: quando
## ci sarà l'account online andrà sostituito con l'id dell'account, altrimenti
## gli acquisti non seguono il giocatore da un dispositivo all'altro.
func user_id() -> String:
	return OS.get_unique_id()


# --------------------------------------------------------------------------
# Interrogazioni usate dal gioco
# --------------------------------------------------------------------------

func has_entitlement(entitlement_id: String) -> bool:
	return _active.has(entitlement_id)


func has_season_pass() -> bool:
	return has_entitlement("season_pass")


## Vero se il giocatore possiede la civiltà, o se è gratuita.
func owns_origin(origin_id: String) -> bool:
	var entitlement_id := Catalog.entitlement_for_origin(origin_id)
	return entitlement_id.is_empty() or has_entitlement(entitlement_id)


func owns_cosmetic(cosmetic_id: String) -> bool:
	var wanted := "skin:%s" % cosmetic_id
	for entitlement_id in _active:
		if Catalog.grants(entitlement_id).has(wanted):
			return true
	return false


## Civiltà utilizzabili in una partita.
##
## In modalità 'shared' tutte le civiltà sono in gioco per tutti e l'acquisto
## sblocca la possibilità di sceglierle: il pool condiviso resta identico per
## ogni giocatore, che è ciò che tiene onesto il competitivo. In modalità
## 'owned' si gioca solo con quelle possedute.
func playable_origins() -> PackedStringArray:
	var all := PackedStringArray()
	for origin_id in GameData.origin_ids():
		all.append(String(origin_id))
	if Catalog.roster_mode() == "shared":
		return all
	var owned := PackedStringArray()
	for origin_id in all:
		if owns_origin(origin_id):
			owned.append(origin_id)
	return owned


## Civiltà che il giocatore può scegliere come preferita/proporre in lobby.
func selectable_origins() -> PackedStringArray:
	var result := PackedStringArray()
	for origin_id in GameData.origin_ids():
		if owns_origin(String(origin_id)):
			result.append(String(origin_id))
	return result


# --------------------------------------------------------------------------
# Comandi
# --------------------------------------------------------------------------

func purchase(entitlement_id: String) -> void:
	if not Catalog.has_entitlement(entitlement_id):
		push_error("Store: entitlement sconosciuto '%s'" % entitlement_id)
		purchase_completed.emit(entitlement_id, false, "entitlement sconosciuto")
		return
	if has_entitlement(entitlement_id):
		purchase_completed.emit(entitlement_id, true, "già posseduto")
		return
	backend.purchase(entitlement_id)


## Da collegare a un pulsante "Ripristina acquisti": su Google Play è un
## requisito, e senza di esso chi reinstalla perde ciò che ha pagato.
func restore_purchases() -> void:
	backend.restore_purchases()


func price_of(entitlement_id: String) -> String:
	return String(products.get(entitlement_id, {}).get("price_string", "—"))


# --------------------------------------------------------------------------

func _on_entitlements_changed(entitlement_ids: PackedStringArray) -> void:
	_active.clear()
	for id in entitlement_ids:
		_active[id] = true
	entitlements_changed.emit()


func _on_purchase_completed(entitlement_id: String, success: bool, reason: String) -> void:
	purchase_completed.emit(entitlement_id, success, reason)


func _on_products_loaded(loaded: Dictionary) -> void:
	products = loaded
	products_loaded.emit(products)
