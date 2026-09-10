class_name StoreBackend
extends RefCounted

## Interfaccia comune a tutti i backend di acquisto.
##
## Il gioco non sa mai se sta parlando con RevenueCat su Android, con Web
## Billing nel browser o con il finto negozio usato in sviluppo: conosce solo
## questi metodi. Aggiungere una piattaforma significa aggiungere una
## sottoclasse, non toccare il resto del codice.

## Emesso quando gli entitlement posseduti cambiano (acquisto, ripristino,
## scadenza di un abbonamento, login con un altro account).
signal entitlements_changed(entitlement_ids: PackedStringArray)
## Emesso al termine di un acquisto. success=false con reason="cancelled"
## quando è l'utente ad annullare: non è un errore da mostrare come tale.
signal purchase_completed(entitlement_id: String, success: bool, reason: String)
## Emesso al termine dell'acquisto di un prodotto che NON concede entitlement —
## oggi solo le donazioni, che sono consumabili e ripetibili. Tenerlo separato
## da purchase_completed evita che la UI degli sblocchi reagisca a un acquisto
## che non sblocca niente.
signal product_purchase_completed(product_id: String, success: bool, reason: String)
## Emesso quando il listino con i prezzi localizzati è disponibile.
signal products_loaded(products: Dictionary)


## Nome leggibile, per log e schermata di debug.
func backend_name() -> String:
	return "astratto"


## Vero se il backend può funzionare sulla piattaforma corrente.
func is_available() -> bool:
	return false


## Inizializza la connessione al negozio. Asincrona: l'esito arriva via
## entitlements_changed.
func initialize(_api_key: String, _user_id: String) -> void:
	pass


## Chiede il listino: prezzi già localizzati e formattati dallo store.
func fetch_products(_entitlement_ids: PackedStringArray) -> void:
	pass


## Avvia il flusso d'acquisto per un entitlement del catalogo.
func purchase(_entitlement_id: String) -> void:
	pass


## Avvia il flusso d'acquisto per un prodotto qualsiasi, senza passare dagli
## entitlement. L'esito arriva su product_purchase_completed.
func purchase_product(_product_id: String) -> void:
	pass


## Associa gli acquisti a un account. Va chiamata quando il giocatore fa il
## login: fino a quel momento il negozio conosce solo un id anonimo di
## dispositivo, e ciò che è stato pagato non seguirebbe il giocatore altrove.
func identify(_user_id: String) -> void:
	pass


## Torna all'utente anonimo, al logout.
func sign_out() -> void:
	pass


## Ripristina gli acquisti già effettuati da questo utente. Su Android è
## obbligatorio esporne un comando: senza, chi reinstalla perde tutto.
func restore_purchases() -> void:
	pass


## Entitlement attivi noti al backend in questo momento.
func active_entitlements() -> PackedStringArray:
	return PackedStringArray()
