extends SceneTree

## Smoke test dell'autenticazione online:
##
##   godot --headless --path . --script res://tests/auth_smoke.gd
##
## Verifica che con l'autoload Auth presente ma sloggato (backend non
## configurato nei test) il menu si costruisca, Auth non forzi il login, e il
## single-player parta comunque. È la garanzia dell'invariante: "il gioco
## offline funziona senza account".
##
## Modello frame-pump come tests/menu_smoke.gd: match _frames in _process, con
## frame di margine per i cambi scena.

var _passed := 0
var _failed := 0
var _frames := 0
var _menu: Control = null


func _process(_delta: float) -> bool:
	_frames += 1

	match _frames:
		1:
			section("Auth: stato di partenza")
			var auth := root.get_node("/root/Auth")
			check(auth != null, "l'autoload Auth esiste")
			check(auth.is_logged_in() == false, "si parte da sloggati")
			check(auth.user_id() == "", "user_id() è \"\" da sloggato")
			check(auth.access_token() == "", "access_token() è \"\" da sloggato")
			auth.logout()
			check(auth.is_logged_in() == false, "logout da sloggato non crasha")
			auth.try_restore_session()
			check(auth.is_logged_in() == false, "try_restore_session senza backend non crasha")
		2:
			section("Menu: si costruisce con Auth presente")
			_menu = (load("res://ui/menu.tscn") as PackedScene).instantiate()
			root.add_child(_menu)
		4:
			check(_menu != null and _menu._store_panel != null,
				"il menu si costruisce con l'autoload Auth registrato")
			check(root.get_node("/root/Auth").is_logged_in() == false,
				"aprire il menu non effettua né forza il login")
			_menu._on_play_pressed()
		6:
			section("Single-player: parte da sloggati e offline")
			var scene := current_scene
			check(scene != null and scene.scene_file_path == "res://ui/main.tscn",
				"premere Battaglia porta in partita anche senza account",
				scene.scene_file_path if scene != null else "nessuna scena")
			check(scene != null and scene.match_state != null,
				"la partita single-player è pronta appena entrati")
			print("\n%d superati, %d falliti" % [_passed, _failed])
			quit(1 if _failed > 0 else 0)

	return false


func section(title: String) -> void:
	print("\n== %s ==" % title)


func check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % label)
	else:
		_failed += 1
		printerr("  FAIL %s%s" % [label, ("  -> " + detail) if detail != "" else ""])
