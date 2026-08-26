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
var combat_speed: float = 1.0
var matches_played: int = 0
var best_placement: int = 0


func _ready() -> void:
	load_profile()


func load_profile() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		# Primo avvio: nessun file, si resta sui valori predefiniti.
		return
	favourite_origin = String(config.get_value("preferences", "favourite_origin", ""))
	combat_speed = float(config.get_value("preferences", "combat_speed", 1.0))
	matches_played = int(config.get_value("stats", "matches_played", 0))
	best_placement = int(config.get_value("stats", "best_placement", 0))
	changed.emit()


func save_profile() -> void:
	var config := ConfigFile.new()
	config.set_value("preferences", "favourite_origin", favourite_origin)
	config.set_value("preferences", "combat_speed", combat_speed)
	config.set_value("stats", "matches_played", matches_played)
	config.set_value("stats", "best_placement", best_placement)
	var error := config.save(SAVE_PATH)
	if error != OK:
		push_error("Profile: salvataggio fallito (%d)" % error)


func set_favourite_origin(origin_id: String) -> void:
	favourite_origin = origin_id
	save_profile()
	changed.emit()


func set_combat_speed(speed: float) -> void:
	combat_speed = speed
	save_profile()
	changed.emit()


## Registra il risultato di una partita conclusa. Il piazzamento migliore è il
## più basso: 1 è la vittoria.
func record_match(placement: int) -> void:
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
