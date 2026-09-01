class_name DevNet
extends RefCounted

## Modalita' di sviluppo locale: fa girare la parte online contro un master e un
## worker Godot headless sulla STESSA macchina, senza Caddy/TLS e senza Supabase.
##
## In produzione il client parla `wss://<game_host>/ws/mm` e `wss://<game_host>/ws/wN`
## (path routing di Caddy) e serve un login Google reale. Per provare il
## multiplayer in locale niente di tutto questo esiste, quindi:
##
##   - lato client: variabile d'ambiente  AUTOCHESS_DEV_LOCAL=1
##       il menu salta il login e va dritto in lobby, RemoteSession usa `ws://`
##       verso 127.0.0.1:9000 (master) e 127.0.0.1:9001 (worker), e manda un
##       token ospite `guestdev-...` al posto del JWT.
##   - lato server: variabile d'ambiente  MASTER_DEV_GUEST=1
##       il master accetta i token `guestdev-...` sintetizzandone i claim.
##
## Nessun file tracciato cambia significato: tutto e' dietro le due env var.

const MASTER_PORT := 9000
const WORKER_PORT := 9001
const GUEST_PREFIX := "guestdev-"


static func enabled() -> bool:
	return OS.get_environment("AUTOCHESS_DEV_LOCAL") == "1"


static func master_url() -> String:
	return "ws://127.0.0.1:%d/ws/mm" % MASTER_PORT


static func worker_url(path: String) -> String:
	var p := path if path.begins_with("/") else "/" + path
	return "ws://127.0.0.1:%d%s" % [WORKER_PORT, p]
