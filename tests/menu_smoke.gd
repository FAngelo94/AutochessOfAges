extends SceneTree

## Smoke test della schermata iniziale:
##
##   godot --headless --path . --script res://tests/menu_smoke.gd
##
## Verifica che il menu si costruisca, che le preferenze si salvino e si
## rileggano, che i pannelli si aprano e che da qui si entri davvero in
## partita. Il passaggio più importante è l'ultimo: se il cambio di scena si
## rompe, il gioco resta bloccato sul menu e nessun altro test se ne accorge.

var _passed := 0
var _failed := 0
var _frames := 0
var _menu: Control = null
var _profile: Node = null
var _saved_favourite := ""
var _saved_hero := ""
var _saved_speed := 1.0
var _saved_matches := 0
var _saved_best := 0
var _saved_tips := PackedStringArray()


func _process(_delta: float) -> bool:
	_frames += 1

	match _frames:
		1:
			_menu = (load("res://ui/menu.tscn") as PackedScene).instantiate()
			root.add_child(_menu)
		2:
			_run()
			# Il cambio di scena ha bisogno di un frame per completarsi: i
			# controlli sul risultato stanno nel passaggio successivo.
			_menu._on_play_pressed()
		4:
			_check_scene_change()
			# Dal gioco si deve poter tornare indietro, altrimenti il menu è
			# una schermata a senso unico.
			current_scene._on_menu_pressed()
		6:
			var back := current_scene
			check(back != null and back.scene_file_path == "res://ui/menu.tscn",
				"dalla partita si torna al menu",
				back.scene_file_path if back != null else "nessuna scena")
			_restore_profile()
			print("\n%d superati, %d falliti" % [_passed, _failed])
			quit(1 if _failed > 0 else 0)

	return false


func _run() -> void:
	_profile = _menu.get_node("/root/Profile")
	# Le preferenze reali dell'utente vanno rimesse a posto a fine test.
	_saved_favourite = _profile.favourite_origin
	_saved_hero = _profile.favourite_hero
	_saved_speed = _profile.combat_speed
	_saved_matches = _profile.matches_played
	_saved_best = _profile.best_placement
	# .duplicate(): PackedStringArray non fa copy-on-write in GDScript, una
	# semplice assegnazione condividerebbe il buffer e append() sul profilo
	# muterebbe anche questa "copia" salvata.
	_saved_tips = _profile.seen_tips.duplicate()

	check(_menu._store_panel != null, "il menu costruisce il pannello del negozio")
	check(_menu._collection_panel != null, "il menu costruisce la collezione")
	check(_menu._guide_panel != null, "il menu costruisce il pannello della guida")
	check(_menu._mode_panel != null, "il menu costruisce la modale di modalità")
	check(_menu._mode_option_buttons.size() == 2, "ci sono due opzioni di modalità",
		str(_menu._mode_option_buttons.size()))
	check(_menu._hero_panel != null, "il menu costruisce la modale eroi")
	check(_menu._hero_option_buttons.size() == GameData.all_heroes().size(),
		"ci sono tante opzioni eroe quanti eroi in heroes.json",
		str(_menu._hero_option_buttons.size()))

	# Collezione: si apre, elenca tutte le unità e mostra una scheda.
	_menu._on_collection_pressed()
	var collection: CollectionPanel = _menu._collection_panel
	check(collection.visible, "la collezione si apre")
	check(collection._grid.get_child_count() == GameData.all_units().size(),
		"la collezione elenca tutte le unità (una casella per unità)",
		"%d di %d" % [collection._grid.get_child_count(), GameData.all_units().size()])
	check(collection._detail.text.length() > 0, "la collezione mostra la scheda di un'unità")

	collection._filter_origin = "roman"
	collection._refresh()
	var romans := 0
	for def in GameData.all_units():
		if def.origin == "roman":
			romans += 1
	check(collection._grid.get_child_count() == romans,
		"il filtro per civiltà riduce l'elenco", str(collection._grid.get_child_count()))
	collection.visible = false

	# Cronologia: da ospite (nessun login) deve aprirsi lo stesso e mostrare le
	# sole partite locali, senza errori — e' il percorso di chi gioca offline.
	var history: HistoryPanel = _menu._history_panel
	var saved_history := MatchLog.local_matches()
	var restore := FileAccess.open(MatchLog.HISTORY_PATH, FileAccess.WRITE)
	if restore != null:
		restore.store_string(JSON.stringify([
			{"mode": "cpu", "placement": 2, "hero_id": "cesare", "hp": 30,
			 "ended_at": "2026-01-01T10:00:00", "units": [{"unit_id": "legionarius", "final_star": 2}]}]))
		restore.close()
	history.open()
	check(history.visible, "la cronologia si apre")
	check(history._list.get_child_count() == 1,
		"la cronologia elenca le partite locali", str(history._list.get_child_count()))
	check(history._status.text.contains("1"), "dice quante partite ci sono", history._status.text)
	history.visible = false
	var put_back := FileAccess.open(MatchLog.HISTORY_PATH, FileAccess.WRITE)
	if put_back != null:
		put_back.store_string(JSON.stringify(saved_history))
		put_back.close()

	# Guida: si apre, elenca tutti i capitoli e marca la voce come vista.
	check(not _profile.has_seen_tip("guide_opened"), "la guida non è ancora stata vista")
	_menu._on_guide_pressed()
	var guide: GuidePanel = _menu._guide_panel
	check(guide.visible, "la guida si apre")
	check(_profile.has_seen_tip("guide_opened"), "aprire la guida marca la voce come vista")

	var sections: Array = GameData.guide_sections()
	var bad_placeholder := ""
	for section in sections:
		var body := TutorialText.expand(String(section.get("body", "")))
		if "{" in body:
			bad_placeholder = String(section.get("id", ""))
	check(bad_placeholder == "", "nessun segnaposto resta non sostituito nella guida", bad_placeholder)
	guide.visible = false

	# reset_tips() rimette in coda tutto, incluso il pulsante della guida.
	_profile.mark_tip_seen("shop")
	_profile.reset_tips()
	check(_profile.seen_tips.is_empty(), "reset_tips svuota i suggerimenti visti")
	check(not _profile.has_seen_tip("guide_opened"), "reset_tips rimette in coda anche la guida")

	# Negozio raggiungibile dal menu, cioè prima di entrare in partita: è
	# l'unico punto d'ingresso, la schermata di battaglia non ha più un
	# proprio pulsante carrello.
	_menu._on_store_pressed()
	check(_menu._store_panel.visible, "il negozio si apre dal menu")
	_check_store_panel(_menu)
	_menu._store_panel.visible = false

	# Modalità: la scelta si salva sul profilo e si ritrova al rientro nel menu.
	# Il valore salvato va scritto e ripristinato esplicitamente: leggere lo stato
	# ambientale di user://profile.cfg renderebbe il test verde una volta sola e
	# rosso per sempre dopo, come già succede ad altri tre test di questo repo.
	var saved_mode: String = _profile.match_mode

	_profile.match_mode = ""
	check(_menu._restored_mode() == _menu.MODE_CPU,
		"senza una modalità salvata si parte da contro il computer")

	_menu._on_mode_pressed(_menu.MODE_PVP)
	check(_menu._match_mode == _menu.MODE_PVP, "si può selezionare la modalità contro giocatori")
	check(not _menu._mode_panel.visible, "selezionare una modalità chiude la modale")
	check(_profile.match_mode == _menu.MODE_PVP, "la scelta della modalità si salva sul profilo")
	check(_menu._restored_mode() == _menu.MODE_PVP,
		"al rientro nel menu si ritrova la modalità salvata")

	_profile.match_mode = "modalita_inventata"
	check(_menu._restored_mode() == _menu.MODE_CPU,
		"una modalità salvata sconosciuta ricade su contro il computer")

	# Il ramo PVP non apre più un dialog "in arrivo": da loggati va in lobby, da
	# sloggati avvia il login Google. Senza backend configurato Auth.login_google()
	# degrada subito a login_completed(false, ...): qui si verifica solo che non
	# si crashi e che NON si esca dal menu (il full path lobby→partita richiede
	# un server e si prova a mano — vedi criteri di accettazione M6).
	var auth := _menu.get_node_or_null("/root/Auth")
	check(auth != null, "l'autoload Auth è presente")
	if auth != null:
		check(not auth.is_logged_in(), "il test parte da sloggati")
		_menu._match_mode = _menu.MODE_PVP
		_menu._on_play_pressed()
		var scene := current_scene
		check(scene == null or scene.scene_file_path != "res://ui/lobby.tscn",
			"da sloggati il tasto Battaglia in PVP non entra in lobby")

	_menu._match_mode = _menu.MODE_CPU
	_profile.set_match_mode(saved_mode)  # il profilo dell'utente torna com'era

	# Eroe: la selezione è obbligatoria, quindi il menu parte sempre con un id
	# valido, e sceglierne uno diverso si salva sul profilo.
	check(_menu._selected_hero != "" and GameData.has_hero(_menu._selected_hero),
		"il menu parte con un eroe valido selezionato", _menu._selected_hero)
	_menu._on_hero_pressed("vercingetorige")
	check(_menu._selected_hero == "vercingetorige", "si può selezionare un altro eroe")
	check(not _menu._hero_panel.visible, "selezionare un eroe chiude la modale")
	check(_profile.favourite_hero == "vercingetorige", "la scelta dell'eroe si salva sul profilo")

	# Velocità delle battaglie e civiltà preferita: si salvano e si rileggono da
	# disco anche senza un selettore nella home, perché il profilo resta usato
	# altrove (ritmo di combattimento, evidenziazione nel negozio).
	_profile.set_combat_speed(4.0)
	_profile.set_favourite_origin("roman")
	var reread := ConfigFile.new()
	check(reread.load("user://profile.cfg") == OK, "il profilo viene scritto su disco")
	check(float(reread.get_value("preferences", "combat_speed", 0.0)) == 4.0,
		"la velocità scelta finisce nel file")
	check(String(reread.get_value("preferences", "favourite_origin", "")) == "roman",
		"la civiltà preferita finisce nel file")
	check(String(reread.get_value("preferences", "favourite_hero", "")) == "vercingetorige",
		"l'eroe scelto finisce nel file")

	_profile.combat_speed = 1.0
	_profile.load_profile()
	check(_profile.combat_speed == 4.0, "il profilo si rilegge correttamente")


func _check_scene_change() -> void:
	var current := current_scene
	check(current != null and current.scene_file_path == "res://ui/main.tscn",
		"premere Battaglia porta in partita",
		current.scene_file_path if current != null else "nessuna scena")
	if current != null and current.has_method("player"):
		check(current.match_state != null, "la partita è pronta appena entrati")
		# La velocità scelta nel menu deve valere già dalla prima battaglia.
		check(is_equal_approx(float(_profile.combat_speed), 4.0),
			"la preferenza di velocità sopravvive al cambio di scena")
		check(current.match_state.human_player().hero_id == "vercingetorige",
			"l'eroe scelto nel menu si propaga al giocatore in partita",
			current.match_state.human_player().hero_id)


## Il negozio deve aprirsi, mostrare una riga per ogni contenuto in vendita e
## riflettere subito ciò che è stato acquistato.
##
## L'autoload si recupera dall'albero invece di usare il nome globale: questo
## script viene compilato prima che gli autoload siano registrati, e "Store"
## non sarebbe ancora un identificatore noto.
func _check_store_panel(menu: Control) -> void:
	var store := menu.get_node("/root/Store")
	var panel: StorePanel = menu._store_panel
	check(panel._rows.size() == Catalog.entitlement_ids().size(),
		"c'è una riga per ogni contenuto in vendita",
		"%d righe" % panel._rows.size())

	var entitlement_id := "cosmetic_pack_legion"
	var button: Button = panel._rows[entitlement_id]
	check(not button.disabled, "un contenuto non posseduto è acquistabile")

	store.purchase(entitlement_id)
	check(store.has_entitlement(entitlement_id), "l'acquisto concede il contenuto")
	check(button.disabled, "dopo l'acquisto il pulsante non è più premibile")
	check(store.owns_cosmetic("roman_gold"), "il cosmetico risulta posseduto")

	# La modalità 'shared' non deve mai togliere civiltà dalla partita: è la
	# garanzia che l'acquisto non tocchi l'equilibrio competitivo.
	check(store.playable_origins().size() == GameData.origin_ids().size(),
		"in modalità condivisa tutte le civiltà restano giocabili")
	check(store.selectable_origins().has("roman"), "la civiltà gratuita è sempre selezionabile")

	# Non lasciare acquisti finti sul disco: il prossimo avvio ripartirebbe
	# con contenuti già sbloccati e i test non sarebbero più ripetibili.
	if store.backend is MockStore:
		(store.backend as MockStore).clear()


## I test non devono lasciare tracce nel profilo di chi sviluppa: partite
## finte e preferenze cambiate comparirebbero nel menu come se fossero vere.
func _restore_profile() -> void:
	_profile.favourite_origin = _saved_favourite
	_profile.favourite_hero = _saved_hero
	_profile.combat_speed = _saved_speed
	_profile.matches_played = _saved_matches
	_profile.best_placement = _saved_best
	_profile.seen_tips = _saved_tips
	_profile.save_profile()


func check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % label)
	else:
		_failed += 1
		printerr("  FAIL %s%s" % [label, ("  -> " + detail) if detail != "" else ""])
