extends SceneTree

## Cattura schermate della schermata di gioco e della battaglia.
##
##   godot --path . --script res://tests/screenshot.gd -- screenshots
##
## Va eseguito SENZA --headless: serve una finestra vera, perché in headless il
## viewport non produce un'immagine. Serve a guardare il risultato invece di
## dedurlo dai test.

var _frames := 0
var _main: Control = null
var _menu: Control = null
var _output_dir := "user://"
var _waiting_portraits := false
var _wait_ticks := 0
## Aprire la guida e vedere il suggerimento del negozio marca entrambi come
## visti sul profilo reale: senza ripristinarlo, chi lancia lo strumento non
## vedrebbe più quei suggerimenti nella prossima partita vera.
var _saved_tips := PackedStringArray()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_output_dir = args[0]


func _process(_delta: float) -> bool:
	_frames += 1

	# I ritratti 3D si generano uno per fotogramma: senza aspettare, le
	# schermate mostrerebbero caselle ancora col nome scritto al posto della
	# figura. Il conteggio dei fotogrammi riprende quando la coda è vuota.
	if _waiting_portraits:
		_wait_ticks += 1
		# Il limite è una rete di sicurezza: se la generazione si inceppa, lo
		# strumento scatta comunque invece di restare appeso per sempre.
		if root.get_node("/root/Portraits").is_idle() or _wait_ticks > 400:
			_waiting_portraits = false
		_frames -= 1
		return false

	match _frames:
		1:
			_menu = (load("res://ui/menu.tscn") as PackedScene).instantiate()
			root.add_child(_menu)
			_saved_tips = root.get_node("/root/Profile").seen_tips.duplicate()
		6:
			_save("menu.png")
			# La guida non mostra modelli 3D: non serve attendere i ritratti.
			_menu._on_guide_pressed()
		7:
			_save("guida.png")
			_menu._guide_panel.visible = false
			_menu._settings_panel.open()
		8:
			_save("impostazioni.png")
			_menu._settings_panel.visible = false
			_menu._on_collection_pressed()
			_waiting_portraits = true
		11:
			_save("collezione.png")
			root.remove_child(_menu)
			_menu.queue_free()
			_main = (load("res://ui/main.tscn") as PackedScene).instantiate()
			root.add_child(_main)
		12:
			_waiting_portraits = true
		13:
			# Una squadra piena rende la schermata rappresentativa: comprarla a
			# caso darebbe uno scatto di un tabellone quasi vuoto.
			var player: Player = _main.player()
			player.level = 6
			player.gold = 42
			var line_up := ["legionarius", "sagittarius", "centurio", "velites", "equites", "ballistarius"]
			var column := 0
			for unit_id in line_up:
				var unit := player.grant_unit(unit_id, 2 if column % 2 == 0 else 1)
				# Sei unita' su cinque colonne: si alternano le due file, e la
				# colonna riparte da zero quando finisce la larghezza del campo.
				var columns := int(GameData.balance()["match"]["board_columns"])
				player.move_to_board(unit, Vector2i(column % columns, 0 if column % 2 == 0 else 3))
				column += 1
			player.grant_unit("cataphractus")
			player.grant_unit("arminius", 2)
			_main._refresh()
		23:
			# Il suggerimento del negozio è ancora in coda da _start_new_match():
			# questa schermata verifica che la bolla non copra COMBATTI né la
			# fila del negozio.
			_save("preparazione.png")
			_main._tips.dismiss()
		24:
			_main._on_fight_pressed()
			# Dalla battaglia ora si esce da soli. Con una battaglia molto corta
			# l'overlay si chiuderebbe prima dello scatto del frame 56 e
			# battaglia.png finirebbe per ritrarre la preparazione.
			_main.result_pause = 1000.0
		56:
			_save("battaglia.png")
		57:
			var profile := root.get_node("/root/Profile")
			profile.seen_tips = _saved_tips
			profile.save_profile()
			print("schermate salvate in %s" % _output_dir)
			quit(0)

	return false


func _save(file_name: String) -> void:
	var image := root.get_texture().get_image()
	var path := _output_dir.path_join(file_name)
	var error := image.save_png(path)
	if error != OK:
		printerr("salvataggio fallito (%d): %s" % [error, path])
