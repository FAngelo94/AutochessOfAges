extends Node

## Preferenze del giocatore che sopravvivono alla singola partita.
## Registrato come autoload "Profile".
##
## Non sta in core/ di proposito: core/ è la simulazione, e la simulazione non
## deve dipendere da cosa un giocatore ha scelto nei menù o da un file su
## disco. Qui invece si scrive e si legge da user://, fuori dal progetto, dove
## i salvataggi non rischiano di finire nel controllo di versione.

signal changed

const SAVE_PATH := "user://profile.cfg"

## Civiltà preferita: puramente una preferenza di comodo. Viene evidenziata nel
## negozio durante la partita e non concede alcun vantaggio — il pool è
## condiviso da tutti, e un bonus legato a un acquisto romperebbe l'equità.
var favourite_origin: String = ""
## Eroe scelto dal giocatore. Vuoto finché non sceglie mai: usare
## effective_hero() per leggere sempre un id valido (default Cesare).
var favourite_hero: String = ""
var combat_speed: float = 1.0
var matches_played: int = 0
var best_placement: int = 0
## Id dei suggerimenti one-shot già mostrati (TipBubble). Una volta visto, un
## suggerimento non ricompare più — a meno di reset_tips().
var seen_tips: PackedStringArray = PackedStringArray()


## Client Supabase per sincronizzare le sole preferenze di account
## (favourite_origin / favourite_hero). Nullo o non configurato -> tutto
## resta locale, esattamente come prima.
var _supabase: SupabaseClient


func _ready() -> void:
	load_profile()
	_supabase = SupabaseClient.new(self)
	var auth := get_node_or_null("/root/Auth")
	if auth != null:
		auth.login_completed.connect(_on_login_completed)


func _on_login_completed(success: bool, _reason: String) -> void:
	if success:
		_pull_remote_preferences()


func _remote_ready() -> bool:
	var auth := get_node_or_null("/root/Auth")
	return auth != null and auth.is_logged_in() \
		and _supabase != null and _supabase.is_configured()


## Al login: le preferenze di account vengono da Supabase e vincono su quelle
## locali. Il resto del profilo (velocità, tip visti) resta di dispositivo.
func _pull_remote_preferences() -> void:
	if not _remote_ready():
		return
	var auth := get_node_or_null("/root/Auth")
	_supabase.get_profile(auth.access_token(), auth.user_id(),
		func(ok: bool, row: Dictionary) -> void:
			if not ok:
				return
			favourite_origin = String(row.get("favourite_origin", favourite_origin))
			favourite_hero = String(row.get("favourite_hero", favourite_hero))
			save_profile()
			changed.emit())


## Al cambio di preferenza, se loggati, si spinge su Supabase. Da sloggati è
## un no-op e vale solo il salvataggio locale.
func _push_remote_preferences() -> void:
	if not _remote_ready():
		return
	var auth := get_node_or_null("/root/Auth")
	_supabase.update_profile(auth.access_token(), auth.user_id(), {
		"favourite_origin": favourite_origin,
		"favourite_hero": favourite_hero,
	}, func(_ok: bool, _row: Dictionary) -> void: pass)


func load_profile() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		# Primo avvio: nessun file, si resta sui valori predefiniti.
		return
	favourite_origin = String(config.get_value("preferences", "favourite_origin", ""))
	favourite_hero = String(config.get_value("preferences", "favourite_hero", ""))
	combat_speed = float(config.get_value("preferences", "combat_speed", 1.0))
	matches_played = int(config.get_value("stats", "matches_played", 0))
	best_placement = int(config.get_value("stats", "best_placement", 0))
	# Assente nei profili salvati prima di questa funzionalità: il default
	# vuoto fa sì che un profilo esistente continui a caricarsi senza errori.
	seen_tips = PackedStringArray(config.get_value("tutorial", "seen_tips", PackedStringArray()))
	changed.emit()


func save_profile() -> void:
	var config := ConfigFile.new()
	config.set_value("preferences", "favourite_origin", favourite_origin)
	config.set_value("preferences", "favourite_hero", favourite_hero)
	config.set_value("preferences", "combat_speed", combat_speed)
	config.set_value("stats", "matches_played", matches_played)
	config.set_value("stats", "best_placement", best_placement)
	config.set_value("tutorial", "seen_tips", seen_tips)
	var error := config.save(SAVE_PATH)
	if error != OK:
		push_error("Profile: salvataggio fallito (%d)" % error)


func set_favourite_origin(origin_id: String) -> void:
	favourite_origin = origin_id
	save_profile()
	_push_remote_preferences()
	changed.emit()


func set_favourite_hero(hero_id: String) -> void:
	favourite_hero = hero_id
	save_profile()
	_push_remote_preferences()
	changed.emit()


## Eroe da usare in partita: la scelta salvata, o Cesare se non è mai stata
## fatta. La selezione è obbligatoria per giocare, ma non blocca il primo
## avvio con un default assente.
func effective_hero() -> String:
	return favourite_hero if favourite_hero != "" else GameData.DEFAULT_HERO_ID


func set_combat_speed(speed: float) -> void:
	combat_speed = speed
	save_profile()
	changed.emit()


## Registra il risultato di una partita conclusa. Il piazzamento migliore è il
## più basso: 1 è la vittoria.
func record_match(placement: int, online := false) -> void:
	if online:
		# Le statistiche delle partite online le possiede il server (le scrive
		# su Supabase con la service_role key). Il client non tocca i contatori.
		return
	matches_played += 1
	if placement > 0 and (best_placement == 0 or placement < best_placement):
		best_placement = placement
	save_profile()
	changed.emit()


func best_placement_text() -> String:
	if best_placement == 0:
		return "—"
	if best_placement == 1:
		return "1° posto"
	return "%d° posto" % best_placement


func has_seen_tip(tip_id: String) -> bool:
	return seen_tips.has(tip_id)


func mark_tip_seen(tip_id: String) -> void:
	if seen_tips.has(tip_id):
		return
	seen_tips.append(tip_id)
	save_profile()
	changed.emit()


## Rimette in coda tutti i suggerimenti one-shot: usato dal pulsante "Rivedi i
## suggerimenti" nella schermata Guida.
func reset_tips() -> void:
	seen_tips = PackedStringArray()
	save_profile()
	changed.emit()
