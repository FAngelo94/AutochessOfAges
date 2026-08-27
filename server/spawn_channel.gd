class_name SpawnChannel
extends RefCounted

## Canale di controllo interno master -> worker (MULTIPLAYER_PLAN.md M4, punto 5).
## Un WebSocketPeer client verso ws://127.0.0.1:<porta worker><path>, NON esposto
## da Caddy. Il master vi manda SPAWN_MATCH; in M5 il worker lo riceve e crea il
## MatchRunner. In M4 il test fornisce un endpoint finto (o nessuno: gli invii
## restano in coda senza bloccare nulla).
##
## Uso: send() accoda, poll() va chiamato a ogni frame dal master per guidare la
## connessione e svuotare la coda.

var _url: String
var _ws := WebSocketPeer.new()
var _queue: Array[PackedByteArray] = []
var _connecting := false


func _init(worker_url: String) -> void:
	_url = worker_url


func send(payload: Dictionary) -> void:
	_queue.append(Protocol.encode(payload))
	if not _connecting:
		_connecting = true
		_ws.connect_to_url(_url)


func poll() -> void:
	if not _connecting:
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			while not _queue.is_empty():
				_ws.put_packet(_queue.pop_front())
		WebSocketPeer.STATE_CLOSED:
			# Riconnessione pigra al prossimo send() se resta roba in coda.
			_connecting = false


func has_pending() -> bool:
	return not _queue.is_empty()
