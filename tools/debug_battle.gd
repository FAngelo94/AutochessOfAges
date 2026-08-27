extends SceneTree

## Lancia il gioco direttamente sulla schermata di battaglia, con una squadra
## già pronta su entrambi i lati, per iterare rapidamente sulla UI di
## combattimento (es. ui/combat_view.gd) senza rifare tutta la fase di
## preparazione ad ogni riavvio.
##
##   godot --path . --script res://tools/debug_battle.gd -- --seed=4242
##
## Va eseguito SENZA --headless: dopo essere entrato in battaglia il gioco
## resta interattivo, la finestra non si chiude da sola.

var _frames := 0
var _main: Control = null


func _process(_delta: float) -> bool:
	_frames += 1

	match _frames:
		1:
			_main = (load("res://ui/main.tscn") as PackedScene).instantiate()
			root.add_child(_main)
		2:
			var player: Player = _main.player()
			player.level = 6
			player.gold = 42
			var line_up := ["legionarius", "sagittarius", "centurio", "velites", "equites", "ballistarius"]
			var column := 0
			for unit_id in line_up:
				var unit := player.grant_unit(unit_id, 2 if column % 2 == 0 else 1)
				var columns := int(GameData.balance()["match"]["board_columns"])
				player.move_to_board(unit, Vector2i(column % columns, 0 if column % 2 == 0 else 3))
				column += 1
			player.grant_unit("cataphractus")
			player.grant_unit("arminius", 2)
			_main._refresh()
		3:
			_main._on_fight_pressed()

	return false
