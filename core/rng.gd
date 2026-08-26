class_name SimRNG
extends RefCounted

## RNG deterministico (xorshift64*) implementato a mano.
##
## Non usiamo RandomNumberGenerator: la sua implementazione può cambiare tra
## versioni di Godot e non garantisce lo stesso stream su piattaforme diverse.
## Qui invece lo stesso seed produce sempre la stessa partita, che è il
## presupposto per far girare la simulazione sul server e replicarla sul client.

## Costanti di mescolamento di xorshift64*. GDScript non accetta letterali
## esadecimali sopra 2^63, quindi la seconda è scritta come il valore con
## segno corrispondente a 0x9E3779B97F4A7C15 (il rapporto aureo a 64 bit).
const MULTIPLIER := 0x2545F4914F6CDD1D
const GOLDEN_GAMMA := -7046029254386353131

var _state: int


func _init(seed_value: int = 1) -> void:
	set_seed(seed_value)


func set_seed(seed_value: int) -> void:
	# Lo stato 0 è un punto fisso di xorshift: va evitato.
	_state = seed_value if seed_value != 0 else MULTIPLIER


func get_state() -> int:
	return _state


func set_state(state: int) -> void:
	_state = state


## Prossimo intero a 64 bit. L'overflow in GDScript fa wrap in complemento a 2,
## che è esattamente il comportamento voluto.
func next_raw() -> int:
	var x := _state
	x ^= x >> 12
	x ^= x << 25
	x ^= x >> 27
	_state = x
	return x * MULTIPLIER


## Intero non negativo a 63 bit.
func next_uint() -> int:
	return next_raw() & 0x7FFFFFFFFFFFFFFF


## Intero in [from, to) con rifiuto del modulo sbilanciato.
func randi_range_ex(from: int, to: int) -> int:
	assert(to > from, "range vuoto: from=%d to=%d" % [from, to])
	var span := to - from
	var limit := 0x7FFFFFFFFFFFFFFF - (0x7FFFFFFFFFFFFFFF % span)
	var value := next_uint()
	while value >= limit:
		value = next_uint()
	return from + (value % span)


## Float in [0, 1).
func randf_ex() -> float:
	return float(next_uint() >> 11) / float(1 << 52)


func chance(probability: float) -> bool:
	return randf_ex() < probability


## Elemento casuale da un array non vuoto.
func pick(array: Array):
	assert(not array.is_empty(), "pick() su array vuoto")
	return array[randi_range_ex(0, array.size())]


## Indice pesato: weights è un array di float non negativi con somma > 0.
func pick_weighted(weights: Array) -> int:
	var total := 0.0
	for w in weights:
		total += float(w)
	assert(total > 0.0, "pick_weighted() con somma dei pesi nulla")
	var roll := randf_ex() * total
	var acc := 0.0
	for i in weights.size():
		acc += float(weights[i])
		if roll < acc:
			return i
	return weights.size() - 1


## Fisher-Yates in place. Muta l'array passato.
func shuffle_ex(array: Array) -> void:
	for i in range(array.size() - 1, 0, -1):
		var j := randi_range_ex(0, i + 1)
		var tmp = array[i]
		array[i] = array[j]
		array[j] = tmp


## Sotto-generatore indipendente, per isolare stream diversi (shop di un
## giocatore vs. combattimento) e non farli interferire tra loro.
func fork(salt: int) -> SimRNG:
	return SimRNG.new(next_raw() ^ (salt * GOLDEN_GAMMA))
