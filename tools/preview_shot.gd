extends SceneTree

## Salva una schermata della vetrina dei modelli.
##
##   godot --path . --script res://tools/preview_shot.gd -- screenshots
##
## Come tests/screenshot.gd, va eseguito SENZA --headless: serve una finestra
## vera perché il viewport produca un'immagine.

var _frames := 0
var _output_dir := "user://"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_output_dir = args[0]


func _process(_delta: float) -> bool:
	_frames += 1
	match _frames:
		1:
			root.add_child((load("res://tools/model_preview.tscn") as PackedScene).instantiate())
		8:
			var image := root.get_texture().get_image()
			var suffix := ""
			for argument in OS.get_cmdline_user_args().slice(1):
				suffix = "_%s" % argument
			var path := _output_dir.path_join("modelli%s.png" % suffix)
			var error := image.save_png(path)
			if error != OK:
				printerr("salvataggio fallito (%d): %s" % [error, path])
			else:
				print("vetrina salvata in %s" % path)
			quit(0)
	return false
