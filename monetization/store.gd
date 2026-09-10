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
## Esito di una donazione, in centesimi: non sblocca niente, quindi non passa
## per gli entitlement.
signal donation_completed(amount_cents: int, success: bool, reason: String)
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
	backend.product_purchase_completed.connect(_on_product_purchase_completed)
	backend.products_loaded.connect(_on_products_loaded)

	var platform := platform_key()
	backend.initialize(Catalog.revenuecat_key(platform), user_id())
	backend.fetch_products(Catalog.entitlement_ids())

	# Auth è un autoload registrato DOPO Store (vedi project.godot): qui non
	# esiste ancora. L'aggancio va rimandato di un frame, e serve comunque —
	# al primo avvio il login arriva molto dopo questo _ready().
	_watch_auth.call_deferred()


## Gli acquisti devono seguire l'account, non il dispositivo. Finché non c'è un
## login il negozio conosce solo OS.get_unique_id(): chi cambia telefono
## perderebbe ciò che ha pagato, e una donazione non sarebbe attribuibile a
## nessun profilo.
func _watch_auth() -> void:
	var auth := get_node_or_null("/root/Auth")
	if auth == null:
		return
	auth.login_completed.connect(func(success: bool, _reason: String) -> void:
		if success:
			backend.identify(user_id()))
	auth.session_restore_finished.connect(func(success: bool) -> void:
		if success:
			backend.identify(user_id()))
	auth.logged_out.connect(func() -> void: backend.sign_out())
	# Una sessione può essere già stata ripristinata prima di questo frame.
	if auth.is_logged_in():
		backend.identify(user_id())


## Prefisso delle chiavi della Test Store di RevenueCat: acquisti finti, nessun
## pagamento reale, e nessuno store dietro.
const TEST_KEY_PREFIX := "test_"


## Il primo backend disponibile vince. Il negozio finto resta in fondo e non
## viene mai scelto su una piattaforma reale.
func _select_backend() -> StoreBackend:
	var candidates: Array[StoreBackend] = [RevenueCatAndroid.new(), RevenueCatWeb.new()]
	for candidate in candidates:
		if candidate.is_available():
			# Una chiave di test in una build pubblicata e' un negozio rotto per
			# tutti: RevenueCat la rifiuta fuori dallo sviluppo. Meglio un
			# negozio assente — il gioco resta interamente giocabile — che un
			# pulsante che non apre nessun pagamento. Il controllo sta qui e non
			# in un README perche' e' l'unico posto che non ci si dimentica di
			# leggere prima di pubblicare.
			if not OS.is_debug_build() \
					and Catalog.revenuecat_key(platform_key()).begins_with(TEST_KEY_PREFIX):
				push_error("Store: chiave di TEST in una build di rilascio — negozio disattivato. "
					+ "Sostituisci revenuecat.%s_api_key in data/catalog.json con la chiave dell'app reale."
					% platform_key())
				return StoreBackend.new()
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
	var a := get_node_or_null("/root/Auth")
	if a != null and a.user_id() != "":
		return a.user_id()
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


## Avvia una donazione di uno dei tagli del catalogo.
##
## `amount_cents` deve essere un taglio esistente: i prezzi su Google Play sono
## fissi e non si puo' addebitare una cifra arbitraria, quindi un importo che
## non corrisponde a un prodotto non viene "avvicinato" al piu' simile — viene
## rifiutato. Addebitare una cifra diversa da quella su cui l'utente ha premuto
## sarebbe indifendibile.
func donate(amount_cents: int) -> void:
	var product := Catalog.donation_product(amount_cents, platform_key())
	if product.is_empty():
		donation_completed.emit(amount_cents, false, "importo non disponibile")
		return
	backend.purchase_product(product)


## Prezzo localizzato di un taglio, "—" se il listino non è ancora arrivato.
func donation_price(amount_cents: int) -> String:
	var product := Catalog.donation_product(amount_cents, platform_key())
	return String(products.get(product, {}).get("price_string", "—"))


## Totale donato noto senza passare dal server. Vale solo per il negozio finto
## in sviluppo: online la sola fonte di verità è il database.
func local_donation_total_cents() -> int:
	if backend.has_method("donated_cents"):
		return int(backend.donated_cents())
	return 0


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


## Il backend parla di prodotti; il gioco di importi.
func _on_product_purchase_completed(product_id: String, success: bool, reason: String) -> void:
	var amount := Catalog.donation_amount_for_product(product_id, platform_key())
	donation_completed.emit(amount, success, reason)


func _on_products_loaded(loaded: Dictionary) -> void:
	products = loaded
	products_loaded.emit(products)
