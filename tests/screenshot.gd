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
var _saved_history: Array = []


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
			# La cronologia chiude il giro: serve di nuovo una schermata di menu
			# viva (quella di partenza e' stata liberata al frame 11) e qualche
			# partita da mostrare, altrimenti si fotografa una lista vuota.
			root.remove_child(_main)
			_main.queue_free()
			_saved_history = MatchLog.local_matches()
			_seed_history()
			_menu = (load("res://ui/menu.tscn") as PackedScene).instantiate()
			root.add_child(_menu)
		58:
			_menu._history_panel.open()
		59:
			_save("cronologia.png")
			var profile := root.get_node("/root/Profile")
			profile.seen_tips = _saved_tips
			profile.save_profile()
			_restore_history()
			print("schermate salvate in %s" % _output_dir)
			quit(0)

	return false


## Cronologia di comodo per lo scatto: tre partite finte, poi si rimette il
## file com'era — user://history.json e' quello di chi sviluppa.
func _seed_history() -> void:
	var rows := [
		{"mode": "cpu", "placement": 1, "hero_id": "cesare", "hp": 74, "rounds": 28,
		 "ended_at": "2026-09-05T18:40:00",
		 "units": [{"unit_id": "legionarius", "final_star": 3}, {"unit_id": "equites", "final_star": 2},
			{"unit_id": "sagittarius", "final_star": 2}]},
		{"mode": "cpu", "placement": 4, "hero_id": "vercingetorige", "hp": 12, "rounds": 24,
		 "ended_at": "2026-09-05T18:05:00",
		 "units": [{"unit_id": "gaul_champion", "final_star": 2}, {"unit_id": "gaul_druid", "final_star": 1}]},
		{"mode": "cpu", "placement": 7, "hero_id": "cesare", "hp": 0, "rounds": 15,
		 "ended_at": "2026-09-04T21:12:00",
		 "units": [{"unit_id": "legionarius", "final_star": 1}]},
	]
	var file := FileAccess.open(MatchLog.HISTORY_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(rows))
		file.close()


func _restore_history() -> void:
	var file := FileAccess.open(MatchLog.HISTORY_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_saved_history))
		file.close()


func _save(file_name: String) -> void:
	var image := root.get_texture().get_image()
	var path := _output_dir.path_join(file_name)
	var error := image.save_png(path)
	if error != OK:
		printerr("salvataggio fallito (%d): %s" % [error, path])
