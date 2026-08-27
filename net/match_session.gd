class_name MatchSession
extends RefCounted

## Astrazione che disaccoppia ui/main.gd dal MatchState locale.
##
## Stesso schema di monetization/store_backend.gd: una classe base con metodi
## virtuali che non fanno nulla, e una sottoclasse per ogni "trasporto" della
## partita. In locale (LocalSession) c'e' un vero MatchState che viene simulato
## qui; online (RemoteSession) il MatchState esiste solo per essere riempito
## dagli snapshot del server, che il client non simula mai.
##
## ui/main.gd LEGGE lo stato direttamente (p.gold, match_state.players, ...) e
## SCRIVE solo attraverso i metodi request_*() di questa interfaccia.

## Lo stato osservabile e' cambiato: la UI deve rinfrescarsi.
signal state_changed
## E' iniziato un nuovo round di preparazione.
signal round_started(stage: int, round_index: int)
## E' pronto un combattimento da mostrare al giocatore locale.
signal combat_ready(combat: Dictionary, team: int)
## Un round si e' concluso: risultati per giocatore (come resolve_round()).
signal round_concluded(results: Array)
## La partita e' finita: classifica finale.
signal match_finished(standings: Array)
## Un comando e' stato rifiutato (fase sbagliata, oro insufficiente, ...).
signal command_rejected(reason: String)
## La connessione col server e' caduta (solo modalita' remota).
signal connection_lost(reason: String)
## E' pronto lo schieramento dell'ultimo combattimento di un altro giocatore,
## chiesto con request_spectate(). combat vuoto = niente da mostrare.
signal spectate_ready(player_index: int, combat: Dictionary, team: int, opponent_hero_id: String)


## Avvia la partita. In locale costruisce il MatchState e i bot; in remoto
## apre la connessione col worker. I parametri servono al percorso locale
## (seed della partita ed eroe del giocatore umano) e sono ignorati in remoto,
## dove seed ed eroe li decide il server.
func begin(_match_seed: int = 0, _hero_id: String = "") -> void:
	pass


## Lo stato della partita, in sola lettura per la UI.
func state() -> MatchState:
	return null


## L'indice del giocatore locale nell'array players.
func local_index() -> int:
	return 0


func request_buy(_slot: int) -> void:
	pass


func request_sell(_uid: int) -> void:
	pass


func request_reroll() -> void:
	pass


func request_buy_xp() -> void:
	pass


func request_move_to_board(_uid: int, _cell: Vector2i) -> void:
	pass


func request_move_to_bench(_uid: int, _slot: int) -> void:
	pass


## Il giocatore locale ha finito la preparazione: risolvi il round.
func request_ready() -> void:
	pass


## Chiede l'ultimo schieramento di un altro giocatore (spettatore). La risposta
## arriva col segnale spectate_ready (sincrono in locale, asincrono in remoto).
func request_spectate(_player_index: int) -> void:
	pass


## Abbandona la partita.
func leave() -> void:
	pass
