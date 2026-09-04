extends Node

## Musica di sottofondo. Registrato come autoload "Music".
##
## Eccezione consapevole alla regola "niente asset su disco": gli effetti sonori
## (Sfx) restano sintetizzati, ma una traccia musicale non si sintetizza in modo
## decente. I file stanno in audio/*.ogg (CC BY 3.0 salvo diversa nota):
##
##   general  audio/general_theme.ogg  "Juniper" — sottofondo di menu, login,
##                                     collezione, negozio, guida, risultati
##   prep     audio/prep_theme.ogg     "Lasting Hope" (Kevin MacLeod), primi 45s
##                                     tagliati — fase di preparazione
##   battle   audio/battle_theme.ogg   "The Ice Giants", intera (44s) tagliati —
##                                     durante le battaglie
##
## Un solo AudioStreamPlayer: si cambia traccia con play_track(), in loop. Se il
## file di una traccia manca, quella resta in silenzio senza errori. Come Sfx,
## su un ambiente headless non costruisce nulla e i metodi sono no-op.

const TRACKS := {
	"general": "res://audio/general_theme.ogg",
	"prep": "res://audio/prep_theme.ogg",
	"battle": "res://audio/battle_theme.ogg",
}

var _player: AudioStreamPlayer
var _streams: Dictionary = {}
var _current := ""
var _music_volume := 0.2


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return

	for key in TRACKS:
		var stream: AudioStream = load(TRACKS[key])
		if stream == null:
			continue
		if stream is AudioStreamOggVorbis:
			(stream as AudioStreamOggVorbis).loop = true
		_streams[key] = stream

	_player = AudioStreamPlayer.new()
	_player.bus = &"Master"
	add_child(_player)

	var profile := get_node_or_null("/root/Profile")
	if profile != null:
		_music_volume = clampf(float(profile.music_volume), 0.0, 1.0)
		profile.changed.connect(_on_profile_changed)
	_apply_volume()


func is_available() -> bool:
	return _player != null


func _on_profile_changed() -> void:
	var profile := get_node_or_null("/root/Profile")
	if profile != null:
		set_volume_linear(float(profile.music_volume))


func set_volume_linear(v: float) -> void:
	_music_volume = clampf(v, 0.0, 1.0)
	_apply_volume()


func _apply_volume() -> void:
	if _player == null:
		return
	_player.volume_db = -80.0 if _music_volume <= 0.001 else linear_to_db(_music_volume)


## Passa alla traccia indicata ("general" / "prep" / "battle"). Se è già quella
## in riproduzione non fa nulla; se il file non c'è resta in silenzio.
func play_track(track: String) -> void:
	if _player == null or track == _current:
		return
	_current = track
	if not _streams.has(track):
		_player.stop()
		return
	_player.stream = _streams[track]
	_player.play()


func stop() -> void:
	_current = ""
	if _player != null:
		_player.stop()


func play_general() -> void:
	play_track("general")


func play_prep() -> void:
	play_track("prep")


func play_battle() -> void:
	play_track("battle")
