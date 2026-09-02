extends SceneTree

## Worker: ospita N MatchRunner in parallelo (MULTIPLAYER_PLAN.md M5).
##
##   godot --headless --path . --script res://server/game_worker.gd -- --port=9001
##
## WebSocketMultiplayerPeer usato come peer GREZZO (poll / get_packet /
## get_packet_peer / set_target_peer), non SceneMultiplayer/@rpc. Tutta la logica
## di partita vive in MatchRunner, testabile in-process (tests/net_smoke.gd);
## questo script e' solo la pompa di frame + i socket + il routing dei pacchetti.
##
## Un solo endpoint per porta: il canale di controllo interno del master
## (SPAWN_MATCH, path Caddy /ws/wN) e i client (JOIN + CMD_*) condividono lo
## stesso WebSocket; si distinguono dal tipo di messaggio.

const DEFAULT_PORT := 9001

## Un runner "finito" resta comunque in _runners per questa finestra: la RPC
## che calcola l'mmr (StatsWriter, via record_match_result) è asincrona e la
## sua risposta arriva quasi sempre dopo che tick() ha già visto FINISHED. Se
## si cancellasse il runner subito, push_rank_update() (server/match_runner.gd)
## scriverebbe in un outbox che nessuno drena più più. tick() su un runner
## finito è un no-op, quindi tenerlo qualche secondo in più costa nulla.
const FINISH_GRACE_MS := 8000

var _peer := WebSocketMultiplayerPeer.new()
var _runners: Dictionary = {}        # match_id -> MatchRunner
var _finished_at: Dictionary = {}    # match_id -> Time.get_ticks_msec() di quando è finito
var _peer_match: Dictionary = {}     # peer_id -> match_id
var _pump: Node


func _initialize() -> void:
	GameData.ensure_loaded()
	var port := _arg_int("port", DEFAULT_PORT)

	var err := _peer.create_server(port)
	if err != OK:
		push_error("worker: impossibile ascoltare sulla porta %d (err %d)" % [port, err])
		quit(1)
		return

	_peer.peer_disconnected.connect(_on_peer_disconnected)
	print("worker: in ascolto su ws://127.0.0.1:%d" % port)


func _process(delta: float) -> bool:
	if _pump == null:
		_pump = Node.new()
		root.add_child(_pump)

	_peer.poll()
	while _peer.get_available_packet_count() > 0:
		var from := _peer.get_packet_peer()
		var bytes := _peer.get_packet()
		_route(from, bytes)

	for match_id in _runners.keys():
		var runner: MatchRunner = _runners[match_id]
		runner.tick(delta)
		_flush(runner)
		if runner.is_finished():
			if not _finished_at.has(match_id):
				_finished_at[match_id] = Time.get_ticks_msec()
			elif Time.get_ticks_msec() - int(_finished_at[match_id]) >= FINISH_GRACE_MS:
				_runners.erase(match_id)
				_finished_at.erase(match_id)
	return false


func _route(peer_id: int, bytes: PackedByteArray) -> void:
	if bytes.size() > Protocol.MAX_PACKET_BYTES:
		_peer.set_target_peer(peer_id)
		_peer.put_packet(Protocol.encode(Protocol.make(Protocol.REJECTED, {"reason": "oversize"})))
		_peer.disconnect_peer(peer_id)
		return
	var msg := Protocol.decode(bytes)
	if msg.is_empty():
		return

	var t := Protocol.message_type(msg)
	if t == Protocol.SPAWN_MATCH:
		_on_spawn(peer_id, msg)
		return

	if t == Protocol.JOIN:
		var mid := String(msg.get("match_id", ""))
		if not _runners.has(mid):
			_peer.set_target_peer(peer_id)
			_peer.put_packet(Protocol.encode(Protocol.make(Protocol.COMMAND_REJECTED, {"reason": "no_match"})))
			return
		_peer_match[peer_id] = mid
		_runners[mid].handle_packet(peer_id, bytes)
		_flush(_runners[mid])
		return

	# Ogni altro pacchetto client va instradato al runner del peer.
	if _peer_match.has(peer_id):
		var runner: MatchRunner = _runners.get(_peer_match[peer_id])
		if runner != null:
			runner.handle_packet(peer_id, bytes)
			_flush(runner)


func _on_spawn(peer_id: int, msg: Dictionary) -> void:
	# SPAWN_MATCH arriva sullo stesso socket dei client: senza questa firma HMAC
	# un client potrebbe forgiarne uno. Il segreto (MATCH_TOKEN_SECRET) è condiviso
	# solo tra master e worker.
	if not MatchToken.verify_control(msg, String(msg.get("spawn_sig", ""))):
		push_warning("worker: SPAWN_MATCH con firma non valida da peer %d — ignorato" % peer_id)
		return
	var mid := String(msg.get("match_id", ""))
	if not _runners.has(mid):
		_runners[mid] = MatchRunner.new(msg, _pump)
		print("worker: SPAWN_MATCH %s seed=%d ranked=%s" % [mid, int(msg.get("seed", 0)), msg.get("ranked", false)])
	_peer.set_target_peer(peer_id)
	_peer.put_packet(Protocol.encode(Protocol.make(Protocol.SPAWN_ACK, {"match_id": mid, "ok": true})))


func _on_peer_disconnected(peer_id: int) -> void:
	if _peer_match.has(peer_id):
		var runner: MatchRunner = _runners.get(_peer_match[peer_id])
		if runner != null:
			runner.handle_disconnect(peer_id)
			_flush(runner)
		_peer_match.erase(peer_id)


func _flush(runner: MatchRunner) -> void:
	for item in runner.pending_outbox():
		var bytes: PackedByteArray = Protocol.encode(item.msg)
		for pid in item.peers:
			_peer.set_target_peer(pid)
			_peer.put_packet(bytes)


func _arg_int(name: String, def: int) -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return int(a.get_slice("=", 1))
	return def
