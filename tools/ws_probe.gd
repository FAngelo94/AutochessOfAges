extends SceneTree

## Sonda diagnostica: apre una WebSocket verso il master e stampa cosa risponde,
## byte per byte. Serve quando il client dice "pacchetto non decodificabile" e
## si vuole sapere se il problema e' il contenuto, la codifica o il server.
##
##   godot --headless --path . --script res://tools/ws_probe.gd -- --host=game.esempio.it
##
## Non modifica niente: manda un solo HELLO e legge. HELLO e' la scelta giusta
## perche' non crea stato sul server — a differenza di AUTH_GOOGLE_BEGIN, che
## parcheggerebbe un login in sospeso.

const TIMEOUT := 8.0

var _ws := WebSocketPeer.new()
var _sent := false
var _started := 0.0


func _initialize() -> void:
	var host := _arg("host", "")
	if host == "":
		var cfg = JSON.parse_string(FileAccess.get_file_as_string("res://data/backend.json"))
		if cfg is Dictionary:
			host = String(cfg.get("game_host", ""))
	if host == "":
		print("manca --host e data/backend.json non ha game_host")
		quit(1)
		return

	var url := "wss://%s/ws/mm" % host
	print("probe -> %s" % url)
	print("PROTOCOL_VERSION del client: %d" % Protocol.PROTOCOL_VERSION)
	var err := _ws.connect_to_url(url)
	if err != OK:
		print("connect_to_url err %d" % err)
		quit(1)
		return
	_started = Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> bool:
	_ws.poll()
	var state := _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN and not _sent:
		_sent = true
		print("stato: OPEN")
		var hello := Protocol.make(Protocol.HELLO, {
			"protocol_version": Protocol.PROTOCOL_VERSION,
			"access_token": "",
		})
		_ws.put_packet(Protocol.encode(hello))
		print("inviato HELLO (%d byte)" % Protocol.encode(hello).size())

	while _ws.get_available_packet_count() > 0:
		var raw := _ws.get_packet()
		# was_string_packet() distingue un frame TESTO da uno BINARIO: e' la
		# prima cosa da guardare, perche' un frame di testo interpretato come
		# var_to_bytes da' esattamente l'errore "header >= VARIANT_MAX".
		var is_text := _ws.was_string_packet()
		print("\n--- pacchetto: %d byte, frame %s" % [raw.size(), "TESTO" if is_text else "BINARIO"])
		print("primi byte (hex): %s" % raw.slice(0, mini(16, raw.size())).hex_encode())
		print("come testo: %s" % raw.get_string_from_utf8().substr(0, 200))
		var decoded := Protocol.decode(raw)
		if decoded.is_empty():
			print("decode: FALLITO (non e' un Dictionary var_to_bytes)")
		else:
			print("decode: ok -> %s" % decoded)

	if state == WebSocketPeer.STATE_CLOSED:
		print("chiuso dal server: codice %d, motivo '%s'" % [
			_ws.get_close_code(), _ws.get_close_reason()])
		quit(0)
		return true

	if Time.get_ticks_msec() / 1000.0 - _started > TIMEOUT:
		print("timeout senza risposta (stato %d)" % state)
		quit(1)
		return true
	return false


static func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return fallback
