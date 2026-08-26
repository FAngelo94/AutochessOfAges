class_name TutorialText
extends RefCounted

## Sostituzione dei segnaposto nei testi di data/tutorial.json (guida e
## suggerimenti one-shot). Condivisa da GuidePanel e TipBubble perché lo
## stesso testo non deve rischiare due implementazioni divergenti.
##
## L'elenco è esplicito invece di appiattire balance.json intero: un
## segnaposto ambiguo (due sezioni con la stessa chiave) darebbe un valore
## sbagliato in silenzio.

static func expand(text: String) -> String:
	var balance := GameData.balance()
	var values := {
		"players": balance["match"]["players"],
		"interest_per": balance["economy"]["interest_per"],
		"max_interest": balance["economy"]["max_interest"],
		"reroll_cost": balance["economy"]["reroll_cost"],
		"buy_xp_cost": balance["economy"]["buy_xp_cost"],
	}
	var result := text
	for key in values:
		# JSON.parse_string legge ogni numero come float: senza int(), "8"
		# comparirebbe come "8.0" nei testi.
		result = result.replace("{%s}" % key, str(int(values[key])))
	return result
