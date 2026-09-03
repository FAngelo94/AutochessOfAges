class_name TutorialText
extends RefCounted

## Sostituzione dei segnaposto nei testi di data/tutorial.json (guida e
## suggerimenti one-shot). Condivisa da GuidePanel e TipBubble perché lo
## stesso testo non deve rischiare due implementazioni divergenti.
##
## L'elenco è esplicito invece di appiattire balance.json intero: un
## segnaposto ambiguo (due sezioni con la stessa chiave) darebbe un valore
## sbagliato in silenzio.

## Segnaposto risolvibili e il loro valore. Pubblica perché i test verifichino
## i testi contro QUESTO elenco invece di tenerne una copia propria: due elenchi
## da allineare a mano sono il modo esatto in cui un segnaposto nuovo finisce a
## schermo fra parentesi graffe.
static func values() -> Dictionary:
	var balance := GameData.balance()
	return {
		"players": balance["match"]["players"],
		"interest_per": balance["economy"]["interest_per"],
		"max_interest": balance["economy"]["max_interest"],
		"reroll_cost": balance["economy"]["reroll_cost"],
		"buy_xp_cost": balance["economy"]["buy_xp_cost"],
		"round_seconds": balance["combat"]["max_duration_seconds"],
		"preparation_seconds": balance["rounds"]["preparation_seconds"],
		# Quanto dura la finestra accelerata, non l'istante in cui comincia: è
		# "gli ultimi N secondi" che si racconta a chi gioca.
		"berserk_seconds": float(balance["combat"]["max_duration_seconds"])
			- float(balance["combat"]["berserk_at_seconds"]),
		"berserk_scale": balance["combat"]["berserk_time_scale"],
	}


static func expand(text: String) -> String:
	var result := text
	var table := values()
	for key in table:
		# JSON.parse_string legge ogni numero come float: senza int(), "8"
		# comparirebbe come "8.0" nei testi.
		result = result.replace("{%s}" % key, str(int(table[key])))
	return result
