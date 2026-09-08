extends SceneTree

## Rasterizza un SVG in PNG alla dimensione voluta. Serve per le icone Android
## (l'esportatore vuole PNG, non SVG) e per guardarsi il disegno senza aprire
## l'editor.
##
##   godot --headless --path . --script res://tools/rasterize_icon.gd -- \
##       res://icon.svg /percorso/uscita.png 512

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		printerr("uso: <sorgente.svg> <destinazione.png> <lato_px>")
		quit(1)
		return
	var src := String(args[0])
	var dst := String(args[1])
	var side := int(args[2])

	var file := FileAccess.open(src, FileAccess.READ)
	if file == null:
		printerr("sorgente non leggibile: ", src)
		quit(1)
		return
	var svg := file.get_as_text()
	file.close()

	var img := Image.new()
	# La scala è relativa alla dimensione dichiarata nell'SVG (512).
	var err := img.load_svg_from_string(svg, float(side) / 512.0)
	if err != OK:
		printerr("rasterizzazione fallita: ", err)
		quit(1)
		return
	if img.get_width() != side:
		img.resize(side, side, Image.INTERPOLATE_LANCZOS)
	err = img.save_png(dst)
	if err != OK:
		printerr("scrittura fallita: ", err)
		quit(1)
		return
	print("scritto ", dst, " (", side, "px)")
	quit()
