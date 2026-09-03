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
var _login: Control = null
## Il test scrive su user://profile.cfg reale (guest_mode): si ripristina alla
## fine, altrimenti una corsa di questo test altera lo stato salvato del gioco.
var _guest_mode_before := false


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

			# login_email/register_email aprono una WebSocket verso il backend se
			# is_configured() è vero: in un checkout con data/backend.json reale
			# (VPS di produzione, vedi SETUP_DB.md) chiamarle qui contatterebbe
			# davvero il server. Si esercita il percorso "senza backend" solo
			# quando l'ambiente lo è davvero — altrove si salta senza fallire.
			if not auth.is_configured():
				section("Auth: email/password senza backend")
				var got_login := [false, "", true]  # [emesso, reason, esito]
				auth.login_completed.connect(func(ok: bool, reason: String) -> void:
					got_login = [true, reason, ok])
				auth.login_email("a@b.it", "password1")
				check(got_login[0] == true and got_login[2] == false,
					"login_email senza backend emette login_completed(false, …) e non crasha")

				got_login = [false, "", true]
				auth.register_email("a@b.it", "password1", "Tizio")
				check(got_login[0] == true and got_login[2] == false,
					"register_email senza backend emette login_completed(false, …) e non crasha")

			section("Auth: validazione email/password")
			check(not auth.email_looks_valid(""), "email vuota non valida")
			check(not auth.email_looks_valid("senzachiocciola"), "email senza @ non valida")
			check(not auth.email_looks_valid("a@b"), "email senza dominio non valida")
			check(not auth.email_looks_valid("a b@c.it"), "email con spazio non valida")
			check(auth.email_looks_valid("a@b.it"), "email valida riconosciuta")
			check(String(auth.password_problem("1234567")) != "", "password di 7 caratteri respinta")
			check(String(auth.password_problem("12345678")) == "", "password di 8 caratteri accettata")

			section("Auth: modalità ospite")
			var profile := root.get_node("/root/Profile")
			_guest_mode_before = bool(profile.guest_mode)
			auth.continue_as_guest()
			check(auth.is_guest() == true, "continue_as_guest() -> is_guest() vero")
			auth.logout()
			check(auth.is_guest() == false, "logout() azzera anche la modalità ospite")
			profile.set_guest_mode(_guest_mode_before)
		2:
			section("Login: res://ui/login.tscn si istanzia senza crashare")
			_login = (load("res://ui/login.tscn") as PackedScene).instantiate()
			root.add_child(_login)
		4:
			var auth2 := root.get_node("/root/Auth")
			if not auth2.is_configured():
				# Invariante offline: senza backend la schermata di login non
				# deve nemmeno comparire, si passa dritti al menu.
				var login_scene := current_scene
				check(login_scene != null and login_scene.scene_file_path == "res://ui/menu.tscn",
					"con backend non configurato, res://ui/login.tscn passa dritto al menu",
					login_scene.scene_file_path if login_scene != null else "nessuna scena")
			else:
				# Backend reale (checkout con data/backend.json compilato): la
				# schermata resta in piedi e costruisce lo stato LOGIN, senza
				# aver tentato nessuna richiesta di rete da sola.
				check(is_instance_valid(_login) and _login.get_child_count() > 0,
					"con backend configurato, res://ui/login.tscn costruisce la sua UI senza crashare")
			section("Menu: si costruisce con Auth presente")
			_menu = (load("res://ui/menu.tscn") as PackedScene).instantiate()
			root.add_child(_menu)
		6:
			check(_menu != null and _menu._store_panel != null,
				"il menu si costruisce con l'autoload Auth registrato")
			check(root.get_node("/root/Auth").is_logged_in() == false,
				"aprire il menu non effettua né forza il login")
			_menu._on_play_pressed()
		8:
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
