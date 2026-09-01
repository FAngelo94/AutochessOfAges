extends Node

## Effetti sonori, sintetizzati a runtime. Registrato come autoload "Sfx".
##
## Il progetto non tiene asset su disco: le figure delle unità, le monete e la
## facciata del castello sono disegnate da codice. I suoni seguono la stessa
## regola — niente file .ogg/.wav, ogni clip è generata all'avvio come
## AudioStreamWAV da onde e rumore con un inviluppo. Sono suoni stilizzati, non
## registrazioni.
##
## Come Portraits, su un ambiente senza audio (i test headless) non si
## costruisce nulla e play() diventa un no-op.

const MIX_RATE := 22050
const POOL_SIZE := 8
## Due eventi uguali nello stesso istante (cleave, colpi multipli in un frame)
## non devono sovrapporsi in un frastuono: la stessa clip non riparte prima di
## questo intervallo.
const THROTTLE_MS := 50

var _clips: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _next_player := 0
var _volume_linear := 0.8
## clip -> tick (ms) dell'ultima riproduzione.
var _last_played: Dictionary = {}


func _ready() -> void:
	if not is_available():
		return

	_clips = {
		"click": _click(),
		"hit": _hit(false),
		"hit_crit": _hit(true),
		"hurt": _hurt(),
		"death_own": _death(false),
		"death_enemy": _death(true),
		"cast": _cast(),
		"round_end": _round_end(),
	}

	for _i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = &"Master"
		add_child(player)
		_players.append(player)

	var profile := get_node_or_null("/root/Profile")
	if profile != null:
		_volume_linear = clampf(float(profile.sfx_volume), 0.0, 1.0)
		profile.changed.connect(_on_profile_changed)
	_apply_volume()


## Falso quando non c'è un dispositivo audio utilizzabile (esecuzioni headless):
## in quel caso le clip non vengono nemmeno sintetizzate e play() non fa nulla.
func is_available() -> bool:
	return DisplayServer.get_name() != "headless"


func _on_profile_changed() -> void:
	var profile := get_node_or_null("/root/Profile")
	if profile != null:
		set_volume_linear(float(profile.sfx_volume))


func set_volume_linear(v: float) -> void:
	_volume_linear = clampf(v, 0.0, 1.0)
	_apply_volume()


func _apply_volume() -> void:
	var db := -80.0 if _volume_linear <= 0.001 else linear_to_db(_volume_linear)
	for player in _players:
		player.volume_db = db


## Riproduce una clip già sintetizzata. Nome sconosciuto, audio non disponibile
## o volume a zero -> non fa nulla.
func play(clip: String, pitch_variation := 0.06) -> void:
	if _players.is_empty() or _volume_linear <= 0.001:
		return
	if not _clips.has(clip):
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_played.get(clip, -10000)) < THROTTLE_MS:
		return
	_last_played[clip] = now

	var player := _players[_next_player]
	_next_player = (_next_player + 1) % _players.size()
	player.stream = _clips[clip]
	player.pitch_scale = 1.0 + randf_range(-pitch_variation, pitch_variation)
	player.play()


# --------------------------------------------------------------------------
# Sintesi
# --------------------------------------------------------------------------

## Converte campioni float in [-1, 1] in un AudioStreamWAV PCM 16 bit mono.
func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(roundf(clampf(samples[i], -1.0, 1.0) * 32767.0)))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = bytes
	return wav


func _samples(seconds: float) -> int:
	return int(seconds * MIX_RATE)


## Inviluppo: attacco lineare corto, poi decadimento esponenziale sul resto.
func _env(i: int, total: int, attack: float) -> float:
	var t := float(i) / float(total)
	if t < attack:
		return t / attack
	return exp(-4.0 * (t - attack) / (1.0 - attack))


func _click() -> AudioStreamWAV:
	var n := _samples(0.045)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var square := 1.0 if sin(TAU * 1500.0 * float(i) / MIX_RATE) >= 0.0 else -1.0
		out[i] = square * _env(i, n, 0.02) * 0.35
	return _wav(out)


## Colpo inferto: un tonfo grave più un burst di rumore che decade in fretta.
## La variante crit è più lunga, più brillante e più forte.
func _hit(crit: bool) -> AudioStreamWAV:
	var n := _samples(0.10 if crit else 0.09)
	var out := PackedFloat32Array()
	out.resize(n)
	var thump_freq := 150.0 if crit else 120.0
	var noise_amt := 0.6 if crit else 0.45
	var gain := 0.55 if crit else 0.4
	for i in n:
		var t := float(i) / MIX_RATE
		var thump := sin(TAU * thump_freq * t) * exp(-30.0 * t)
		var noise := randf_range(-1.0, 1.0) * exp(-45.0 * t)
		out[i] = clampf(thump * 0.6 + noise * noise_amt, -1.0, 1.0) * gain
	return _wav(out)


## Colpo ricevuto: timbro distinto da _hit — pitch che cala, più rumore.
func _hurt() -> AudioStreamWAV:
	var n := _samples(0.13)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / MIX_RATE
		var f := lerpf(420.0, 180.0, clampf(t / 0.13, 0.0, 1.0))
		var noise := randf_range(-1.0, 1.0) * 0.5
		out[i] = (sin(TAU * f * t) * 0.6 + noise * 0.4) * _env(i, n, 0.01) * 0.4
	return _wav(out)


## Morte: tono discendente. Grave per le unità dello spettatore, più acuto per
## quelle avversarie.
func _death(enemy: bool) -> AudioStreamWAV:
	var n := _samples(0.26)
	var out := PackedFloat32Array()
	out.resize(n)
	var f0 := 330.0 if enemy else 220.0
	for i in n:
		var t := float(i) / MIX_RATE
		var f := lerpf(f0, f0 * 0.4, clampf(t / 0.26, 0.0, 1.0))
		out[i] = sin(TAU * f * t) * _env(i, n, 0.02) * 0.4
	return _wav(out)


## Cast di abilità: whoosh ascendente con un filo di shimmer in apertura.
func _cast() -> AudioStreamWAV:
	var n := _samples(0.22)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / MIX_RATE
		var prog := clampf(t / 0.22, 0.0, 1.0)
		var tone := sin(TAU * lerpf(300.0, 900.0, prog) * t)
		var shimmer := randf_range(-1.0, 1.0) * 0.15 * (1.0 - prog)
		out[i] = (tone * 0.5 + shimmer) * _env(i, n, 0.15) * 0.3
	return _wav(out)


## Fine round: due note, uno stacco netto.
func _round_end() -> AudioStreamWAV:
	var n := _samples(0.34)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / MIX_RATE
		var f := 440.0 if t < 0.14 else 660.0
		out[i] = sin(TAU * f * t) * _env(i, n, 0.02) * 0.34
	return _wav(out)
