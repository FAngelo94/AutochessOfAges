extends Control

## Schermata di gioco. Costruisce l'interfaccia da codice: a questo stadio i
## controlli cambiano di continuo e un .tscn scritto a mano sarebbe solo un
## file difficile da leggere in più.
##
## Questo script LEGGE lo stato della partita e invia comandi; non calcola
## nulla. Ogni regola sta in core/. Se qui comparisse un numero di
## bilanciamento, sarebbe nel posto sbagliato.

## Le caselle ospitano il modello 3D dell'unità: sono più alte che larghe per
## lasciare spazio alla figura sopra il distintivo di costo o stelle.
## Proporzioni di un esagono con la punta in alto: la larghezza sta all'altezza
## come √3 sta a 2. Rispettarle è ciò che permette alle righe di incastrarsi.
## Queste tre non sono la dimensione delle caselle: sono la dimensione MINIMA.
## Il viewport è 720×1280 con stretch keep_width, quindi su uno schermo 20:9 la
## tela è alta 1600 e restano trecento pixel che nessuno reclama. _apply_metrics()
## li distribuisce ingrandendo le caselle; dove non avanza niente (16:9, o una
## finestra piccola sul desktop) il fattore vale 1.0 e valgono esattamente questi
## numeri.
const CELL_SIZE := Vector2(86, 100)
const SHOP_SLOT_SIZE := Vector2(106, 110)
const BENCH_SLOT_SIZE := SHOP_SLOT_SIZE
## Casella compatta per la lista di tutte le unità di una sinergia nel
## modale di dettaglio — più piccola delle altre perché lì serve solo
## riconoscere il modello, non interagire con la casella.
const SYNERGY_UNIT_SLOT_SIZE := Vector2(56, 64)

## Pulsanti icona a destra di panchina (esperienza) e negozio (aggiorna). La
## larghezza è fissa, l'altezza la detta la casella a cui stanno a fianco.
const ICON_BUTTON_SIZE := Vector2(97, 64)

## Le righe dispari della plancia risalgono di un quarto d'altezza su quella
## sopra: è ciò che incastra gli esagoni invece di lasciarli in file staccate.
const BOARD_OVERLAP := 0.25

## Oltre non si va: i ritratti sono renderizzati a 192 px (Portraits.SIZE) e i
## distintivi di costo e stelle hanno un corpo fisso, quindi una casella più
## grande non guadagna più nulla — comincerebbe solo a sgranare.
const MAX_SLOT_SCALE := 1.6

## Spazio tenuto da parte per ciò che cresce a partita in corso.
##
## La misura si fa al primo round, quando la scheda delle sinergie ha una riga
## sola; a squadra piena ne ha due o tre, e sono una cinquantina di pixel
## ciascuna. Senza questa riserva le caselle si prenderebbero tutto lo spazio
## disponibile al minuto zero, e la barra di scorrimento comparirebbe da sola
## alla terza unità schierata. Riscalare le caselle a ogni cambio di sinergia
## sarebbe l'alternativa, ma una plancia che si ridimensiona mentre si gioca è
## peggio di un po' di spazio tenuto libero.
const CONTENT_HEADROOM := 124.0

## Margini e spaziature del guscio: servono anche al calcolo dello spazio
## disponibile, e una copia sfasata darebbe una stima sbagliata di poco, che è
## il modo peggiore di sbagliare.
const SIDE_MARGIN := 16

## In preparazione la scheda delle sinergie sta a destra della plancia, in una
## colonna di larghezza fissa che ospita una colonna di chip a simbolo, una
## per riga: una sola per riga occupa molto meno che la vecchia griglia 2×N,
## quindi questa colonna può restare stretta e lasciare più margine alla
## plancia. Il tetto di larghezza della plancia in _slot_scales() sottrae
## questi due valori.
const SYNERGY_COL_WIDTH := 180.0
const SYNERGY_COL_GAP := 8

const TOP_MARGIN := 38
const BOTTOM_MARGIN := 18
const ROOT_SEPARATION := 12

## Margine interno e bordo della piastra sotto la striscia avversari: entrano
## nel conto della larghezza delle chip, che devono starci in quattro per riga.
const RANKING_PLATE_INSET := 8
const RANKING_PLATE_BORDER := 2

## Quante chip per riga nella striscia della classifica. Due righe da quattro
## invece di una da otto: un nome tagliato a meta' non dice chi e' l'avversario,
## e la seconda riga costa molta meno altezza di quanta leggibilita' restituisca.
const RANKING_CHIPS_PER_ROW := 4

## Aria fra una chip e l'altra. A 4 px la vita di una finiva appiccicata alla
## posizione della successiva e le due si leggevano come un unico numero: qui
## la separazione conta più della larghezza, perché le chip non hanno una
## cornice che dica dove finisce l'una e comincia l'altra.
const RANKING_CHIP_H_SEPARATION := 14
const RANKING_CHIP_V_SEPARATION := 6

## Altezze della barra comandi. Sono sotto i minimi tattili di Style
## (TOUCH_MIN / TOUCH_PRIMARY) di proposito: quei valori nascono per pulsanti
## isolati, mentre qui la riga e' larga quanto lo schermo e il bersaglio resta
## enorme in orizzontale. L'altezza recuperata va alla plancia, che e' la cosa
## che si guarda.
const BAR_BUTTON_HEIGHT := 52.0
const PRIMARY_BUTTON_HEIGHT := 76.0

## Quanti caratteri di un nome si mostrano nella classifica prima di troncarlo.
## I nomi arrivano dal server e possono essere lunghi a piacere; una chip larga
## un quarto di striscia non li regge, e tagliare a una misura dichiarata e'
## meglio che lasciar decidere al clip_text quanto testo sparisce.
const MAX_NAME_CHARS := 10

## In locale il MatchState e' quello di _session; in remoto sara' lo stesso
## oggetto, solo riempito dagli snapshot del server. La UI lo legge e basta.
var match_state: MatchState
var selected: UnitInstance = null

## Da dove arriva la partita. LOCAL: simulata qui da LocalSession. REMOTE:
## decisa da un server autoritativo (MULTIPLAYER_PLAN.md M6).
enum SessionMode { LOCAL, REMOTE }
var session_mode: int = SessionMode.LOCAL
var _session: MatchSession

var _round_label: Label
var _hp_label: Label
var _gold_label: Label
var _level_label: Label
var _rank_label: Label
var _stats_label: RichTextLabel
var _log_label: RichTextLabel
var _shop_row: HBoxContainer
var _board_rows: VBoxContainer
var _bench_row: HBoxContainer
var _ranking_list: HFlowContainer
var _synergy_row: GridContainer
var _fight_button: Button
var _sell_button: Button

## Modalità remota: al posto di COMBATTI, un countdown di preparazione e PRONTO.
var _prep_bar: VBoxContainer
var _prep_label: Label
var _ready_button: Button
## Barra del tempo di preparazione, in fondo allo schermo. In remoto rispecchia
## il countdown del server; in locale è un conto alla rovescia nostro che allo
## scadere fa partire il round da solo, così le due modalità hanno lo stesso
## ritmo invece di una che aspetta all'infinito.
var _prep_phase_bar: PhaseBar
## Secondi che restano alla preparazione locale. < 0 = disarmato (battaglia in
## corso, partita finita, o giocatore eliminato).
var _prep_left: float = -1.0
## Ultimo secondo intero per cui è stato emesso il bip del conto alla rovescia
## (ultimi 10 s di preparazione). -1 = nessuno / fuori dalla finestra.
var _last_prep_beep: int = -1
var _reconnect_panel: Panel

## I controlli di negozio, griglia e panchina hanno numero fisso: vengono
## creati una volta sola e poi solo aggiornati. Ricostruirli a ogni refresh
## significherebbe distruggere il pulsante dentro il cui gestore ci troviamo,
## e accumulare nodi in attesa di queue_free() a ogni interazione.
var _shop_buttons: Array[UnitSlot] = []
var _cell_buttons: Dictionary = {}
var _bench_buttons: Array[UnitSlot] = []

## Spaziatori di mezza cella in testa alle righe dispari della plancia. Vanno
## tenuti da parte perché lo sfalsamento è metà della LARGHEZZA di una cella:
## se le celle crescono e lo spaziatore no, le righe smettono di incastrarsi.
var _row_offsets: Array[Control] = []
## Acquista esperienza (accanto alla panchina) e aggiorna il negozio (accanto al
## negozio): servono come membri solo per pareggiarne l'altezza a quella delle
## caselle a cui stanno a fianco, in _apply_metrics().
var _xp_button: Button
var _reroll_button: Button

## Il guscio della preparazione, tenuto da parte per misurare quanto spazio
## resta al corpo che scorre: colonna radice, scroll centrale e suo contenuto.
var _root_column: VBoxContainer
var _scroll: ScrollContainer
var _body: VBoxContainer
## Fattore di scala in vigore per plancia, panchina e negozio (x, y, z). Serve a
## _apply_metrics() per risalire alla parte FISSA dell'altezza del corpo
## sottraendo dalla misura attuale ciò che dipende dal fattore stesso.
var _slot_scale := Vector3.ONE

var _store: Node
var _profile: Node
var _combat_overlay: Control
var _combat_controls: Control
## Barra del tempo della battaglia. Scorre sull'orologio reale, non su quello
## della riproduzione: quando la propria battaglia finisce prima del limite
## continua ad avanzare finché non si torna in preparazione — è il segnale che
## si sta aspettando gli altri scontri, non che il gioco si è piantato.
var _combat_bar: PhaseBar
var _combat_bar_elapsed: float = 0.0
var _info_sheet: Panel
var _synergy_detail: Control
var _synergy_detail_backdrop: ColorRect
var _synergy_detail_title: Label
var _synergy_detail_description: Label
var _synergy_detail_tiers: VBoxContainer
var _synergy_detail_units: GridContainer
var _combat_view: CombatView
var _tips: TipBubble
var _combat_title: Label
var _combat_top_bar: HBoxContainer
var _combat_top_name: Label
var _combat_top_hp: Label
var _combat_top_synergy_row: HBoxContainer
var _combat_bottom_bar: HBoxContainer
var _combat_bottom_hp: Label
var _combat_bottom_synergy_row: HBoxContainer
var _combat_outcome: Label
var _combat_hint: Label
var _spectate_overlay: Panel
var _spectate_view: CombatView
var _spectate_title: Label
## Risultati del round in attesa: vengono raccontati solo a fine replay, per
## non svelare l'esito mentre la battaglia è ancora in corso.
var _pending_results: Array = []

## Schermata classifica: prende il posto della preparazione per chi è stato
## eliminato, e fa da riepilogo finale per tutti a partita conclusa.
var _spectator_screen: Panel
var _spectator_title: Label
var _spectator_subtitle: Label
## Stato dei giocatori ancora in partita: round in corso, fase (preparazione con
## countdown o battaglia). Visibile solo per chi è eliminato a partita in corso.
var _spectator_status: Label
var _spectator_rows: VBoxContainer
var _spectator_restart: Button

## Attesa prima di lasciare la battaglia da soli: il fascio del risultato più il
## tempo di leggere l'esito. Una var e non una const perché gli strumenti
## headless la spostano (tests/screenshot.gd la alza per non farsi chiudere
## l'overlay sotto lo scatto).
var result_pause := 1.6

## Conto alla rovescia dell'uscita automatica. < 0 = disarmato. Un contatore in
## _process invece di un SceneTreeTimer: è ispezionabile dai test headless, si
## annulla riassegnando, e non lascia una callback in volo dopo un cambio partita.
var _auto_close_left: float = -1.0

## Classifica finale normalizzata (LocalSession manda Array[Player],
## RemoteSession Array[Dictionary]). Vuota finché la partita non è decisa.
var _final_standings: Array = []
var _match_recorded := false

## Uid delle unità appena fuse a una stella più alta (Player.unit_upgraded),
## in attesa che _refresh_board/_refresh_bench ridisegnino la loro casella e
## possano farla lampeggiare. Svuotato man mano che ogni casella lo consuma.
var _level_up_pending: Dictionary = {}


func _exit_tree() -> void:
	# Tornando al menu la musica generale riprende; la imposta anche menu.gd,
	# qui si evita solo il buco durante il cambio scena.
	var music := get_node_or_null("/root/Music")
	if music != null:
		music.play_general()


func _ready() -> void:
	GameData.ensure_loaded()
	_store = get_node("/root/Store")
	_profile = get_node("/root/Profile")
	_build_ui()
	_build_slot_buttons()
	_start_new_match()

	# Le caselle nascono alla dimensione minima e vengono subito riscalate allo
	# schermo vero. Dopo _start_new_match(), non dentro _build_slot_buttons():
	# la misura del corpo ha senso solo quando sinergie e avversari hanno già le
	# loro chip, o si calcolerebbe lo spazio di una schermata che non esiste.
	_apply_metrics()
	get_viewport().size_changed.connect(_apply_metrics)


func player() -> Player:
	return match_state.human_player()


## Seed della partita. Normalmente casuale, ma si può fissare da riga di
## comando:
##
##   godot --path . -- --seed=4242
##
## Serve a riprodurre una partita identica — per inseguire un bug segnalato,
## o per avere test ripetibili invece che dipendenti dall'orologio.
func _requested_seed() -> int:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--seed="):
			return int(argument.trim_prefix("--seed="))
	return 0


## Disattiva i suggerimenti one-shot: utile per gli screenshot e per chi
## vuole giocare senza interruzioni.
##
##   godot --path . -- --no-tips
func _tips_requested() -> bool:
	return "--no-tips" not in OS.get_cmdline_user_args()


# --------------------------------------------------------------------------
# Costruzione dell'interfaccia
# --------------------------------------------------------------------------

func _build_ui() -> void:
	add_child(Style.backdrop(Style.SKY_TOP, Style.SKY_BOTTOM))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", SIDE_MARGIN)
	margin.add_theme_constant_override("margin_right", SIDE_MARGIN)
	# In alto la tacca del telefono, in basso la barra dei gesti.
	margin.add_theme_constant_override("margin_top", TOP_MARGIN)
	margin.add_theme_constant_override("margin_bottom", BOTTOM_MARGIN)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", ROOT_SEPARATION)
	margin.add_child(root)
	_root_column = root

	root.add_child(_build_hud())

	# Il centro scorre, le due barre no: su un telefono 16:9 griglia, panchina e
	# negozio insieme non ci stanno in altezza, ma vita e oro in cima e Combatti
	# in fondo devono restare dove sono senza doverli cercare.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_scroll = scroll

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)
	_body = body

	# Una riga per HBox invece di una griglia unica: il campo è esagonale, e le
	# righe dispari vanno sfalsate di mezza cella. Una GridContainer allinea le
	# colonne per costruzione, e mostrerebbe adiacenze che in battaglia non
	# esistono — chi schiera deve vedere gli stessi vicini che vedrà il
	# risolutore.
	# Plancia a sinistra, sinergie in colonna a destra. La plancia non è più
	# centrata: si àncora a sinistra e la colonna dei simboli si prende la
	# fascia di destra, così le due cose che cambiano a ogni mossa — dove
	# stanno le unità e quali tratti sono attivi — si guardano senza scorrere.
	var board_row := HBoxContainer.new()
	board_row.add_theme_constant_override("separation", SYNERGY_COL_GAP)
	body.add_child(board_row)

	_board_rows = VBoxContainer.new()
	_board_rows.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# Separazione negativa: due righe di esagoni si incastrano risalendo di un
	# quarto d'altezza l'una sull'altra. Con una separazione positiva resterebbero
	# due file di esagoni staccate, che non è una griglia esagonale.
	_board_rows.add_theme_constant_override("separation", int(-CELL_SIZE.y * 0.25))
	board_row.add_child(_board_rows)

	var synergy_side := VBoxContainer.new()
	synergy_side.custom_minimum_size = Vector2(SYNERGY_COL_WIDTH, 0)
	synergy_side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	synergy_side.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	synergy_side.add_theme_constant_override("separation", 4)
	board_row.add_child(synergy_side)

	synergy_side.add_child(_section_title("SINERGIE"))
	synergy_side.add_child(_build_synergy_card())

	body.add_child(_spacer(6))

	# Ogni riga di caselle ha il proprio pulsante icona a destra, accoppiato per
	# significato invece che per comodità di layout: l'esperienza governa il
	# livello, cioè quante unità si schierano dalla panchina; l'aggiornamento
	# governa il negozio. Il costo sta nel tooltip e nella monetina, non scritto
	# per esteso, così le caselle si prendono tutta la larghezza che avanza.
	var bench_row_wrap := HBoxContainer.new()
	bench_row_wrap.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	bench_row_wrap.add_theme_constant_override("separation", 6)
	body.add_child(bench_row_wrap)

	_bench_row = HBoxContainer.new()
	_bench_row.add_theme_constant_override("separation", 4)
	bench_row_wrap.add_child(_bench_row)

	_xp_button = _shop_icon_button(
		"📈", "Esperienza", int(GameData.balance()["economy"]["buy_xp_cost"]))
	_xp_button.pressed.connect(_on_buy_xp_pressed)
	bench_row_wrap.add_child(_xp_button)

	body.add_child(_spacer(6))
	body.add_child(_section_title("NEGOZIO"))

	var shop_row_wrap := HBoxContainer.new()
	shop_row_wrap.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	shop_row_wrap.add_theme_constant_override("separation", 6)
	body.add_child(shop_row_wrap)

	_shop_row = HBoxContainer.new()
	_shop_row.add_theme_constant_override("separation", 6)
	shop_row_wrap.add_child(_shop_row)

	_reroll_button = _shop_icon_button(
		"🔄", "Aggiorna", int(GameData.balance()["economy"]["reroll_cost"]))
	_reroll_button.pressed.connect(_on_reroll_pressed)
	shop_row_wrap.add_child(_reroll_button)

	# Nel flusso del layout, non come overlay ancorato: quando compare, spinge
	# la barra dei comandi verso il basso invece di coprire COMBATTI.
	_tips = TipBubble.new()
	_tips.enabled = _tips_requested()
	root.add_child(_tips)

	root.add_child(_build_action_bar())

	# Sovrapposizioni, dalla meno alla più invadente: l'ordine di aggiunta è
	# l'ordine di disegno, e la battaglia deve poter coprire tutto il resto.
	_build_info_sheet()

	# La classifica copre la preparazione di chi è fuori; la battaglia copre la
	# classifica; il replay di un avversario si apre sopra la classifica, ed è
	# per questo che va aggiunto per ultimo.
	_build_spectator_screen()
	_build_combat_overlay()
	_build_spectate_overlay()

	# Il dettaglio di una sinergia si può aprire anche DURANTE la battaglia
	# (una chip nelle barre alto/basso): va costruito per ultimo, o resterebbe
	# sotto l'overlay di combattimento e il click non mostrerebbe nulla.
	_build_synergy_detail()


## Barra di stato: round, vita, oro, livello. Sono i quattro numeri su cui si
## decide ogni turno, quindi stanno in cima e non scorrono via.
func _build_hud() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)

	_round_label = Label.new()
	_round_label.add_theme_font_size_override("font_size", 26)
	_round_label.add_theme_color_override("font_color", Style.GOLD)
	column.add_child(_round_label)

	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 8)
	column.add_child(chips)

	_hp_label = _chip(chips, _glyph_label("❤", Color(0.92, 0.45, 0.45)))
	_gold_label = _chip(chips, Style.coin(22.0))
	# Il livello porta "6  (12/24)": è il contenuto più largo dei quattro e senza
	# una fetta maggiore va a capo. La posizione è due caratteri, e ne chiede meno.
	_level_label = _chip(chips, _glyph_label("⬆", Style.BLUE), 1.4)
	_rank_label = _chip(chips, _glyph_label("🏆", Style.GOLD), 0.7,
		"Posizione attuale. A parità di vita sta davanti chi l'ha persa più tardi.")

	# RichTextLabel (non Label) solo per poter evidenziare in rosso/grassetto il
	# conteggio "Unità X/Y" quando il campo non è pieno — vedi _refresh().
	_stats_label = RichTextLabel.new()
	_stats_label.bbcode_enabled = true
	_stats_label.fit_content = true
	_stats_label.scroll_active = false
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_stats_label.add_theme_font_size_override("normal_font_size", 18)
	_stats_label.add_theme_font_size_override("bold_font_size", 18)
	_stats_label.add_theme_color_override("default_color", Style.TEXT_DIM)
	column.add_child(_stats_label)

	# Subito sotto nome/unità/serie, sempre visibile e non in fondo allo
	# scroll: è l'altro numero che si controlla a ogni mossa.
	column.add_child(_build_ranking_strip())

	return column


## Icona testuale per _chip(). Sta a parte perché l'oro non è un carattere ma un
## cerchio disegnato (Style.coin): _chip prende un Control, non una String.
func _glyph_label(icon: String, tint: Color) -> Label:
	var glyph := Label.new()
	glyph.text = icon
	glyph.add_theme_font_size_override("font_size", 20)
	glyph.add_theme_color_override("font_color", tint)
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return glyph


## Una card dell'HUD. `stretch` regola la fetta di riga: le card sono
## EXPAND_FILL e da tre sono diventate quattro, quindi a fette uguali il livello
## verrebbe troncato. Restituisce la Label del valore, che il chiamante tiene e
## aggiorna in _refresh().
func _chip(row: HBoxContainer, glyph: Control, stretch: float = 1.0, tip: String = "") -> Label:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = stretch
	panel.add_theme_stylebox_override("panel", Style.plate(Style.PLATE_DARK, Style.PLATE, 12, 3))
	if tip != "":
		panel.tooltip_text = tip
	row.add_child(panel)

	var box := HBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	box.add_child(glyph)

	var value := Label.new()
	value.add_theme_font_size_override("font_size", 20)
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	box.add_child(value)
	return value


## Pulsante icona ai lati della riga del negozio (aggiorna, esperienza): solo
## il glifo, come i pulsanti della barra d'azione — il costo resta consultabile
## nel tooltip invece di occupare spazio in riga. Il costo compare comunque
## anche scritto sul pulsante — con l'icona della moneta al posto della
## parola "oro" — così non serve tenere premuto per scoprirlo.
func _shop_icon_button(icon: String, action_label: String, cost: int) -> Button:
	var button := Button.new()
	button.tooltip_text = "%s · %d oro" % [action_label, cost]
	button.custom_minimum_size = ICON_BUTTON_SIZE
	Style.apply_plate(button, Style.PLATE, Style.PLATE_DARK, 14, 4)

	# Il testo del pulsante resta vuoto: la moneta è un nodo disegnato e il testo
	# di un Button non può contenerne uno. Dentro ci va una riga con i figli a
	# MOUSE_FILTER_IGNORE, così i clic arrivano comunque al pulsante — lo stesso
	# schema delle righe della classifica avversari e di UnitSlot.
	var inner := HBoxContainer.new()
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inner.alignment = BoxContainer.ALIGNMENT_CENTER
	inner.add_theme_constant_override("separation", 4)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(inner)

	for text in [icon, str(cost)]:
		var label := Label.new()
		label.text = text
		label.add_theme_font_size_override("font_size", 20)
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(label)

	inner.add_child(Style.coin(16.0))
	return button


## Le due file di comandi in fondo: le azioni di contorno sopra, Combatti da
## solo sotto. Il pollice riposa lì, e quello è il pulsante che si preme più
## spesso — accanto agli altri finirebbe premuto per sbaglio.
func _build_action_bar() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)

	var minor := HBoxContainer.new()
	minor.add_theme_constant_override("separation", 8)
	column.add_child(minor)

	# Vendi porta una parola e un numero, gli altri due una sola icona: a fette
	# uguali il primo verrebbe troncato e gli altri sprecherebbero spazio.
	_sell_button = _bar_button(minor, "Vendi", Style.PLATE)
	_sell_button.size_flags_stretch_ratio = 2.0
	_sell_button.disabled = true
	_sell_button.pressed.connect(_on_sell_pressed)

	_bar_button(minor, "ⓘ", Style.PLATE).pressed.connect(func() -> void: _info_sheet.visible = true)

	# Una freccia che esce da una sponda, non le tre righe del menu a panino:
	# il pulsante non apre un pannello, riporta alla home, e la freccia lo dice
	# senza doverlo leggere nel tooltip.
	var leave_button := _bar_button(minor, "⇤", Style.PLATE)
	leave_button.tooltip_text = "Torna al menu principale"
	leave_button.pressed.connect(_on_menu_button_pressed)

	_fight_button = Button.new()
	_fight_button.text = "COMBATTI"
	_fight_button.custom_minimum_size = Vector2(0, PRIMARY_BUTTON_HEIGHT)
	_fight_button.add_theme_font_size_override("font_size", 38)
	_fight_button.add_theme_color_override("font_color", Style.INK)
	_fight_button.add_theme_color_override("font_hover_color", Style.INK)
	_fight_button.add_theme_color_override("font_pressed_color", Style.INK)
	Style.apply_plate(_fight_button, Style.GOLD, Style.GOLD_DEEP, 20, 8)
	_fight_button.pressed.connect(_on_fight_pressed)
	column.add_child(_fight_button)

	# Modalità remota: il tick del round è del server, non di un bottone. Al
	# posto di COMBATTI, il tempo di preparazione rimasto e un PRONTO che dice
	# al server "ho finito" (il round si chiude comunque allo scadere).
	_prep_bar = VBoxContainer.new()
	_prep_bar.add_theme_constant_override("separation", 4)
	_prep_bar.visible = false
	column.add_child(_prep_bar)

	_prep_label = Label.new()
	_prep_label.add_theme_font_size_override("font_size", 20)
	_prep_label.add_theme_color_override("font_color", Style.GOLD)
	_prep_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prep_bar.add_child(_prep_label)

	_ready_button = Button.new()
	_ready_button.text = "PRONTO"
	_ready_button.custom_minimum_size = Vector2(0, PRIMARY_BUTTON_HEIGHT)
	_ready_button.add_theme_font_size_override("font_size", 34)
	_ready_button.add_theme_color_override("font_color", Style.INK)
	_ready_button.add_theme_color_override("font_hover_color", Style.INK)
	_ready_button.add_theme_color_override("font_pressed_color", Style.INK)
	Style.apply_plate(_ready_button, Style.GOLD, Style.GOLD_DEEP, 20, 8)
	_ready_button.pressed.connect(_on_ready_pressed)
	_prep_bar.add_child(_ready_button)

	# La stessa barra della battaglia, in fondo alla schermata: le due fasi
	# durano lo stesso tempo, e mostrarle con lo stesso oggetto è ciò che lo
	# rende leggibile a colpo d'occhio. Vive fuori da _prep_bar perché quello è
	# il blocco della sola modalità remota, mentre la barra vale anche in
	# locale — dove allo scadere il round parte da sé.
	_prep_phase_bar = PhaseBar.new()
	_prep_phase_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prep_phase_bar.show_remaining = true
	column.add_child(_prep_phase_bar)

	return column


func _bar_button(row: HBoxContainer, text: String, fill: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, BAR_BUTTON_HEIGHT)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 24)
	Style.apply_plate(button, fill, Style.PLATE_DARK, 16, 5)
	row.add_child(button)
	return button


## Cronaca in un foglio richiamabile invece che in colonna a lato: in portrait
## una seconda colonna non esiste, ed è il registro della battaglia — non le
## sinergie, ora sulla schermata principale — la cosa che si consulta ogni
## tanto e non a ogni tocco come griglia e negozio.
func _build_info_sheet() -> void:
	_info_sheet = Panel.new()
	_info_sheet.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_info_sheet.add_theme_stylebox_override("panel", Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	_info_sheet.visible = false
	add_child(_info_sheet)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	_info_sheet.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	column.add_child(_section_title("CRONACA"))

	_log_label = RichTextLabel.new()
	_log_label.bbcode_enabled = true
	_log_label.add_theme_font_size_override("normal_font_size", 18)
	_log_label.add_theme_font_size_override("bold_font_size", 18)
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_log_label)

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 24)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 16, 5)
	close.pressed.connect(func() -> void: _info_sheet.visible = false)
	column.add_child(close)


## Schermata di battaglia: copre il gioco mentre la si guarda, e si può
## accelerare o saltare. Sta sopra a tutto, quindi va aggiunta per ultima.
func _build_combat_overlay() -> void:
	_combat_overlay = Panel.new()
	_combat_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Il pannello resta trasparente: il fondale è lo sfondo crepuscolare qui
	# sotto, non più il nero piatto di prima.
	_combat_overlay.add_theme_stylebox_override("panel", Style.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0))
	_combat_overlay.visible = false
	add_child(_combat_overlay)

	# Crepuscolo di battaglia: più scuro e più freddo del cielo del menu, con
	# un accenno di rosso in basso, così lo schermo segnala "si combatte" anche
	# prima di leggere una riga di testo.
	_combat_overlay.add_child(Style.backdrop(Color(0.02, 0.03, 0.07), Color(0.17, 0.05, 0.09)))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	_combat_overlay.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	box.add_child(_build_combat_top_bar())

	_combat_title = Label.new()
	_combat_title.add_theme_font_size_override("font_size", 24)
	_combat_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_combat_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_combat_title)

	# La battaglia si prende tutto lo spazio che avanza: la camera 3D si adatta
	# al riquadro, quindi darle l'altezza residua è l'unico modo perché su un
	# telefono lungo non resti una cartolina in mezzo allo schermo.
	_combat_view = CombatView.new()
	_combat_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_combat_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_combat_view.playback_finished.connect(_on_playback_finished)
	box.add_child(_combat_view)

	box.add_child(_build_combat_bottom_bar())

	_combat_outcome = Label.new()
	_combat_outcome.add_theme_font_size_override("font_size", 18)
	_combat_outcome.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_combat_outcome.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_combat_outcome)

	# Al posto dei vecchi ×1/×2/×4, la barra del tempo del round. La battaglia
	# si guarda alla velocità a cui è stata combattuta: l'accelerazione non è
	# più una scelta di chi guarda ma una regola del gioco, e negli ultimi
	# secondi arriva da sé (vedi il berserk in core/combat_sim.gd).
	var controls := VBoxContainer.new()
	controls.add_theme_constant_override("separation", 4)
	box.add_child(controls)

	_combat_bar = PhaseBar.new()
	_combat_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(_combat_bar)

	# Niente "Salta" e niente "Continua": dalla battaglia non si esce a mano.
	# Le battaglie di un round durano tempi diversi, e uscire in anticipo voleva
	# dire trovarsi su una preparazione che il server non aveva ancora riaperto,
	# col negozio del round prima. Ora si esce da soli quando sono finite tutte —
	# vedi _request_overlay_close(). Al posto del pulsante, un avviso che dice
	# cosa si sta aspettando, nella stessa riga così l'altezza non salta.
	_combat_hint = Label.new()
	_combat_hint.text = "Si torna alla preparazione…"
	_combat_hint.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	_combat_hint.add_theme_font_size_override("font_size", 18)
	_combat_hint.add_theme_color_override("font_color", Style.TEXT_DIM)
	_combat_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_combat_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_combat_hint.visible = false
	box.add_child(_combat_hint)

	_combat_controls = controls


## Riga in alto: chi si sta affrontando in questo round, la sua vita e le sue
## sinergie attive — le stesse informazioni che in fase di preparazione si
## leggono aprendo la classifica avversari, qui a colpo d'occhio mentre si
## guarda la battaglia.
func _build_combat_top_bar() -> Control:
	_combat_top_bar = HBoxContainer.new()
	_combat_top_bar.add_theme_constant_override("separation", 8)

	_combat_top_name = Label.new()
	_combat_top_name.add_theme_font_size_override("font_size", 15)
	_combat_top_name.add_theme_color_override("font_color", Style.TEXT_DIM)
	_combat_top_name.clip_text = true
	_combat_top_bar.add_child(_combat_top_name)

	_combat_top_hp = Label.new()
	_combat_top_hp.add_theme_font_size_override("font_size", 15)
	_combat_top_hp.add_theme_color_override("font_color", Color(0.92, 0.45, 0.42))
	_combat_top_bar.add_child(_combat_top_hp)

	_combat_top_synergy_row = HBoxContainer.new()
	_combat_top_synergy_row.add_theme_constant_override("separation", 4)
	_combat_top_synergy_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_combat_top_bar.add_child(_combat_top_synergy_row)

	return _combat_top_bar


## Riga in basso: le stesse informazioni ma per la propria squadra — la vita
## che si sta rischiando in questo round e le sinergie che la stanno
## sostenendo, senza dover uscire dalla battaglia per ricordarsele.
func _build_combat_bottom_bar() -> Control:
	_combat_bottom_bar = HBoxContainer.new()
	_combat_bottom_bar.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = "Tu"
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Style.TEXT_DIM)
	_combat_bottom_bar.add_child(label)

	_combat_bottom_hp = Label.new()
	_combat_bottom_hp.add_theme_font_size_override("font_size", 15)
	_combat_bottom_hp.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5))
	_combat_bottom_bar.add_child(_combat_bottom_hp)

	_combat_bottom_synergy_row = HBoxContainer.new()
	_combat_bottom_synergy_row.add_theme_constant_override("separation", 4)
	_combat_bottom_synergy_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_combat_bottom_bar.add_child(_combat_bottom_synergy_row)

	return _combat_bottom_bar


## Ripopola le due barre a ogni round: chiamata da _show_combat() con lo
## stesso dizionario "own" restituito da resolve_round(). Un round fantasma
## (own["opponent"] == null) nasconde la barra dell'avversario invece di
## leggere campi che non esistono.
func _refresh_combat_info(own: Dictionary) -> void:
	var opponent: Player = own.get("opponent")
	if opponent == null:
		_combat_top_bar.visible = false
	else:
		_combat_top_bar.visible = true
		_combat_top_name.text = opponent.display_name
		_combat_top_hp.text = "❤ %d" % opponent.hp
		_refresh_combat_synergy_row(_combat_top_synergy_row, opponent.board_units())

	_combat_bottom_hp.text = "❤ %d" % player().hp
	_refresh_combat_synergy_row(_combat_bottom_synergy_row, player().board_units())


func _refresh_combat_synergy_row(row: HBoxContainer, units: Array) -> void:
	for child in row.get_children():
		child.queue_free()
	for synergy_row in TraitResolver.summary(units):
		if bool(synergy_row["active"]):
			row.add_child(_combat_chip(synergy_row, units))


## Versione compatta di _synergy_chip() per le barre della schermata di
## battaglia: mostra solo il simbolo del tratto, ma è cliccabile — apre il
## dettaglio di quella sinergia contato sulla squadra `units` (la propria o
## quella dell'avversario, a seconda della barra).
func _combat_chip(row: Dictionary, units: Array) -> Control:
	var tint: Color = Style.origin_color(String(row["id"])) if bool(row["is_origin"]) else Style.BLUE

	var button := Button.new()
	button.text = String(row["symbol"])
	button.tooltip_text = String(row["name"])
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 30)
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", tint.lightened(0.35))
	Style.apply_plate(button, tint.darkened(0.55), tint, 8, 3)
	button.pressed.connect(_open_synergy_detail.bind(String(row["id"]), units))

	return button


## Overlay per RIVEDERE la battaglia dell'ultimo round di un altro giocatore:
## il log arriva già completo (SPECTATE_DATA porta combat, team e l'eroe
## avversario), quindi si riproduce come la propria, con i comandi di velocità.
## Non ha un "continua" perché non c'è un round da concludere: si chiude e basta.
## Un CombatView separato da quello della propria battaglia: condividere lo
## stesso avrebbe richiesto salvare e ripristinare lo stato del round in corso
## ogni volta che si apre e si chiude, per un semplice sguardo a un tabellone.
func _build_spectate_overlay() -> void:
	_spectate_overlay = Panel.new()
	_spectate_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_spectate_overlay.add_theme_stylebox_override("panel", Style.box(Style.INK, Style.INK, 0, 0))
	_spectate_overlay.visible = false
	add_child(_spectate_overlay)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	_spectate_overlay.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	_spectate_title = Label.new()
	_spectate_title.add_theme_font_size_override("font_size", 24)
	_spectate_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_spectate_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_spectate_title)

	_spectate_view = CombatView.new()
	_spectate_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spectate_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_spectate_view)

	var speeds := HBoxContainer.new()
	speeds.add_theme_constant_override("separation", 8)
	box.add_child(speeds)
	for speed in [1.0, 2.0, 4.0]:
		var button := Button.new()
		button.text = "×%d" % int(speed)
		button.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 24)
		Style.apply_plate(button, Style.PLATE, Style.PLATE_DARK, 16, 5)
		button.pressed.connect(func() -> void: _spectate_view.speed = speed)
		speeds.add_child(button)

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 24)
	Style.apply_plate(close, Style.PLATE, Style.PLATE_DARK, 16, 5)
	# pause() e non solo visible=false: un CombatView nascosto ma in riproduzione
	# continua a girare in _process dietro al pannello.
	close.pressed.connect(func() -> void:
		_spectate_view.pause()
		_spectate_overlay.visible = false)
	box.add_child(close)


## Rivede la battaglia dell'ultimo round di `pl`. Se quel giocatore non ha
## combattuto (round fantasma, posto già eliminato, o prima battaglia non ancora
## avvenuta) la sessione non risponde affatto: per questo chi disegna le righe
## chiede prima _session.can_spectate() e spegne quelle mute, invece di lasciare
## un tocco che non produce niente.
func _open_spectate(pl: Player) -> void:
	# La sessione risponde con spectate_ready: sincrono in locale (il client ha
	# tutti i log), asincrono in remoto (il worker manda solo il tuo log di
	# combattimento, quello altrui va chiesto — MULTIPLAYER_PLAN.md A5).
	_session.request_spectate(pl.index)


func _on_spectate_ready(player_index: int, combat: Dictionary, team: int, opponent_hero_id: String) -> void:
	if combat.is_empty():
		return  # niente da mostrare (round a vuoto / fantasma)
	var pl: Player = null
	if player_index >= 0 and player_index < match_state.players.size():
		pl = match_state.players[player_index]
	_spectate_title.text = "Ultima battaglia — %s" % (pl.display_name if pl != null else "?")
	_spectate_view.set_hero_portraits(pl.hero_id if pl != null else "", opponent_hero_id)
	_spectate_view.speed = float(_profile.combat_speed)
	_spectate_view.load_combat(combat, team)
	_spectate_overlay.visible = true
	_spectate_view.play()


## Striscia sotto lo schieramento con tutti gli otto giocatori ordinati per vita
## rimasta — la propria riga compresa, in blu — su due righe da quattro: dice a
## colpo d'occhio chi è messo peggio e a che altezza si sta, senza dover aprire
## il foglio delle sinergie per controllare i piazzamenti.
##
## HFlowContainer e non una ScrollContainer orizzontale: le chip sono larghe un
## quarto della striscia, quindi va a capo da sé dopo la quarta. Uno scorrimento
## orizzontale annidato dentro quello verticale del corpo si contenderebbe
## invece il gesto del dito, che è un modo di fallire che l'andare a capo non ha.
func _build_ranking_strip() -> Control:
	# La piastra la mette il riquadro, non le chip: _style_ranking_row lascia lo
	# stato normale trasparente (era dentro un PanelContainer anche prima), e
	# senza uno sfondo dietro le righe galleggerebbero sul fondale. Stessa
	# scheda delle sinergie, che sta appena sotto.
	# I 18 px di margine interno di Style.plate qui sono troppi: tolgono 36 px
	# alle chip, che sono già la cosa più stretta della schermata. La
	# piastra resta la stessa, con il fianco ridotto.
	var plate := Style.plate(Style.PLATE, Style.PLATE_DARK, 12, 4)
	plate.content_margin_left = RANKING_PLATE_INSET
	plate.content_margin_right = RANKING_PLATE_INSET
	plate.content_margin_top = 6
	plate.content_margin_bottom = 6

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", plate)

	_ranking_list = HFlowContainer.new()
	_ranking_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ranking_list.add_theme_constant_override("h_separation", RANKING_CHIP_H_SEPARATION)
	_ranking_list.add_theme_constant_override("v_separation", RANKING_CHIP_V_SEPARATION)
	panel.add_child(_ranking_list)

	return panel


## Ricostruisce la classifica: le righe sono poche (otto) e cambiano
## posizione a ogni round, quindi rifare le righe da zero costa meno che
## tenerle in sincrono manualmente.
func _refresh_ranking() -> void:
	if _ranking_list == null:
		return
	for child in _ranking_list.get_children():
		child.queue_free()

	# Ordine dell'intera classifica, non solo degli avversari: la posizione
	# mostrata deve essere quella vera fra otto, quindi si numera live_ranking()
	# e si saltano le proprie righe invece di ordinare un sottoinsieme.
	# Ci sta dentro anche la propria riga, evidenziata: la posizione degli altri
	# si legge solo rispetto alla propria, e saltarla obbligava a contare a mente
	# fra quale coppia di chip ci si trova.
	var standings := match_state.live_ranking()
	var width := _chip_width(RANKING_CHIPS_PER_ROW)
	# -1 fuori dalla preparazione, da eliminato, o (online) finché il server non
	# l'ha comunicato: nessuna chip viene segnata, ed è il comportamento giusto.
	var next_opp := _session.next_opponent_index() if _session != null else -1
	var position := 0
	for pl in standings:
		position += 1
		_ranking_list.add_child(
			_standing_chip(pl, position, width, pl == player(), pl.index == next_opp))


## Larghezza di una chip perché ne stiano RANKING_CHIPS_PER_ROW per riga: la
## divisione è esatta, così l'HFlowContainer va a capo esattamente dove previsto
## — due righe da quattro — senza doverglielo imporre.
##
## Serve dichiararla: il contenuto della chip è ancorato dentro il pulsante
## (come in UnitSlot, così il tocco arriva sempre al pulsante e non a
## un'etichetta), e un figlio ancorato non concorre alla dimensione minima del
## genitore. Senza questa, le chip si accavallerebbero tutte a larghezza
## zero. Sotto gli 84 px non si scende: si preferisce che vadano a capo.
func _chip_width(count: int) -> float:
	var available := get_viewport_rect().size.x - SIDE_MARGIN * 2.0 \
		- (RANKING_PLATE_INSET + RANKING_PLATE_BORDER) * 2.0 - _scrollbar_width()
	return maxf(84.0, floorf((available - float(RANKING_CHIP_H_SEPARATION) * (count - 1)) / float(count)))


## Larghezza della barra di scorrimento verticale, contata SEMPRE, anche quando
## non c'è. Su uno schermo 16:9 il corpo scorre e la barra si prende una decina
## di pixel: senza tenerne conto le chip stanno larghe esattamente quanto lo
## spazio calcolato, ne avanza una, e la striscia va a capo dove non deve solo
## su certi schermi. Meglio dieci pixel d'aria ovunque che un layout che cambia
## forma a seconda del telefono.
func _scrollbar_width() -> float:
	if _scroll == null:
		return 0.0
	var bar := _scroll.get_v_scroll_bar()
	if bar == null:
		return 0.0
	return maxf(bar.get_combined_minimum_size().x, bar.size.x)


## Una chip della striscia avversari: gli stessi dati di _standing_row messi su
## una riga sola. Sono due funzioni e non una parametrizzata perché le due viste
## hanno forme opposte — qui si comprime in orizzontale e si taglia il nome, là
## (schermata di chi è eliminato) si occupa tutta la larghezza — e il tentativo
## di servirle entrambe produrrebbe una funzione fatta di rami.
const CHIP_FONT := 15

## Aria interna di una chip della classifica, fra il bordo e il suo contenuto
## (posizione, nome, vita). Orizzontale più generoso del verticale: la chip è
## bassa e un margine alto/basso grande la farebbe crescere di riga.
const CHIP_INNER_PAD := 8
const CHIP_INNER_PAD_V := 3

func _standing_chip(pl: Player, position: int, width: float, own: bool = false,
		next_opponent: bool = false) -> Button:
	var out := pl.eliminated or pl.hp <= 0
	var watchable: bool = _session != null and _session.can_spectate(pl.index)

	var chip := Button.new()
	chip.custom_minimum_size = Vector2(width, Style.TOUCH_MIN * 0.55)
	chip.disabled = not watchable
	chip.tooltip_text = "Rivedi l'ultima battaglia di %s" % pl.display_name if watchable \
		else "%s non ha una battaglia da rivedere" % pl.display_name
	# La spada e il bordo acceso segnano l'avversario del round che sta per
	# iniziare: la riga resta comunque toccabile (o spenta) come le altre.
	if next_opponent:
		chip.tooltip_text = "Prossimo avversario. " + chip.tooltip_text
	_style_ranking_row(chip, next_opponent)
	if watchable:
		chip.pressed.connect(_open_spectate.bind(pl))

	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 5)
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Il contenuto è ancorato al pulsante (così il tocco arriva sempre alla chip),
	# quindi i content_margin dello stylebox non lo toccano: l'aria interna la
	# danno questi offset — senza, "1°" e la vita restano incollati ai bordi.
	inner.offset_left = CHIP_INNER_PAD
	inner.offset_right = -CHIP_INNER_PAD
	inner.offset_top = CHIP_INNER_PAD_V
	inner.offset_bottom = -CHIP_INNER_PAD_V
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(inner)

	if next_opponent:
		var sword := Label.new()
		sword.text = "⚔"
		sword.add_theme_font_size_override("font_size", CHIP_FONT)
		sword.add_theme_color_override("font_color", Style.TORCH)
		sword.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(sword)

	var place_label := Label.new()
	place_label.text = "%d°" % position
	place_label.add_theme_font_size_override("font_size", CHIP_FONT)
	place_label.add_theme_color_override("font_color", Style.GOLD.darkened(0.1))
	place_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(place_label)

	# Il nome si taglia, la vita no: in una striscia stretta è il numero che si
	# cerca, e un "55" mozzato a "5" racconterebbe una partita diversa.
	var name_label := Label.new()
	name_label.text = _short_name(pl.display_name)
	name_label.add_theme_font_size_override("font_size", CHIP_FONT)
	name_label.custom_minimum_size = Vector2(float(CHIP_FONT) * 2.6, 0)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(name_label)

	var hp_label := Label.new()
	hp_label.text = "☠" if out else str(pl.hp)
	hp_label.add_theme_font_size_override("font_size", CHIP_FONT)
	hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(hp_label)

	if out:
		name_label.add_theme_color_override("font_color", Style.TEXT_DIM)
		hp_label.add_theme_color_override("font_color", Style.TEXT_DIM)
	else:
		hp_label.add_theme_color_override("font_color", Color(0.92, 0.45, 0.45))

	# Il proprio nome in blu, e nient'altro: è l'unica riga che si cerca senza
	# leggere, e il blu è il colore che nel resto della schermata vuol dire
	# "io". Una piastra colorata dietro la chip diceva la stessa cosa gridando,
	# e in una striscia di otto chip vicine pesava più della classifica stessa.
	# Vale anche da eliminato, dove sovrascrive il grigio di TEXT_DIM: sapere
	# dove si è finiti conta più che vedersi spenti come gli altri.
	if own:
		name_label.add_theme_color_override("font_color", Style.BLUE)

	# Niente lente in coda, a differenza di _standing_row: su una chip da ~94 px
	# quei quattordici pixel li toglierebbe al nome, che è l'unica cosa già
	# costretta a tagliarsi. L'affordance la dà la piastra di _style_ranking_row,
	# spenta quando non c'è battaglia da rivedere.
	return chip


## Nome accorciato a MAX_NAME_CHARS con i puntini: il taglio è dichiarato qui e
## non lasciato al clip_text della chip, che sparirebbe una quantità di testo
## diversa a ogni larghezza di schermo — due giocatori con lo stesso prefisso
## finirebbero indistinguibili su un telefono e distinti su un altro.
func _short_name(name: String) -> String:
	if name.length() <= MAX_NAME_CHARS:
		return name
	return name.substr(0, MAX_NAME_CHARS - 1).strip_edges() + "…"


## Una riga di classifica: posizione, nome, vita (o teschio) e la lente se c'è
## davvero una battaglia da rivedere. Condivisa fra il riquadro stretto accanto
## allo schieramento e la schermata a tutto schermo di chi è eliminato, così le
## due viste non possono raccontare due ordini diversi.
##
## I figli ignorano il mouse, così il clic arriva sempre al pulsante che li
## contiene (come in UnitSlot). Non `flat`: senza uno stato hover e pressed la
## riga non sembra toccabile — una piastra minima dà l'affordance senza rubare
## spazio nel riquadro stretto.
func _standing_row(parent: Control, pl: Player, position: int, font_size: int) -> void:
	var out := pl.eliminated or pl.hp <= 0
	# Una riga che non risponde è peggio di una riga spenta: qui è il tocco
	# principale della schermata spettatore, e il silenzio della sessione
	# sarebbe indistinguibile da un tocco perso.
	var watchable: bool = _session != null and _session.can_spectate(pl.index)

	var row := Button.new()
	row.custom_minimum_size = Vector2(0, Style.TOUCH_MIN * (0.4 if font_size <= 15 else 0.55))
	row.disabled = not watchable
	row.tooltip_text = "Rivedi l'ultima battaglia di %s" % pl.display_name if watchable \
		else "%s non ha una battaglia da rivedere" % pl.display_name
	_style_ranking_row(row)
	if watchable:
		row.pressed.connect(_open_spectate.bind(pl))
	parent.add_child(row)

	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(inner)

	var place_label := Label.new()
	place_label.text = "%d°" % position
	place_label.add_theme_font_size_override("font_size", font_size)
	place_label.add_theme_color_override("font_color", Style.GOLD.darkened(0.1))
	place_label.custom_minimum_size = Vector2(float(font_size) * 1.9, 0)
	place_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(place_label)

	var name_label := Label.new()
	name_label.text = pl.display_name
	name_label.add_theme_font_size_override("font_size", font_size)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(name_label)
	if pl == player():
		name_label.add_theme_color_override("font_color", Style.GOLD)

	var hp_label := Label.new()
	hp_label.add_theme_font_size_override("font_size", font_size)
	hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(hp_label)

	# Lente in coda: segnala che la riga apre un dettaglio, senza dover
	# leggere il tooltip (assente su touch).
	var peek := Label.new()
	peek.text = "🔍" if watchable else " "
	peek.add_theme_font_size_override("font_size", font_size - 2)
	peek.add_theme_color_override("font_color", Style.TEXT_DIM)
	peek.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(peek)

	if out:
		hp_label.text = "☠"
		if pl != player():
			name_label.add_theme_color_override("font_color", Style.TEXT_DIM)
		hp_label.add_theme_color_override("font_color", Style.TEXT_DIM)
	else:
		hp_label.text = str(pl.hp)
		hp_label.add_theme_color_override("font_color", Color(0.92, 0.45, 0.45))


## Schermata che prende il posto della preparazione per chi è fuori dai giochi:
## eliminato a metà partita, oppure partita conclusa (allora la vedono tutti,
## vincitore compreso, come riepilogo finale).
##
## Non è un ramo separato del ciclo di gioco: è un pannello che copre la
## preparazione, quindi _refresh() continua a girare identico sotto e la
## classifica si aggiorna a ogni round senza codice di sincronizzazione.
func _build_spectator_screen() -> void:
	_spectator_screen = Panel.new()
	_spectator_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_spectator_screen.add_theme_stylebox_override("panel",
		Style.box(Style.SKY_TOP, Style.SKY_TOP, 0, 0))
	_spectator_screen.visible = false
	add_child(_spectator_screen)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 18)
	_spectator_screen.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	_spectator_title = Label.new()
	_spectator_title.add_theme_font_size_override("font_size", 30)
	_spectator_title.add_theme_color_override("font_color", Style.GOLD)
	_spectator_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spectator_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_spectator_title)

	_spectator_subtitle = Label.new()
	_spectator_subtitle.add_theme_font_size_override("font_size", 18)
	_spectator_subtitle.add_theme_color_override("font_color", Style.TEXT_DIM)
	_spectator_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spectator_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_spectator_subtitle)

	_spectator_status = Label.new()
	_spectator_status.add_theme_font_size_override("font_size", 16)
	_spectator_status.add_theme_color_override("font_color", Style.GOLD.darkened(0.15))
	_spectator_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spectator_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_spectator_status.visible = false
	box.add_child(_spectator_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_spectator_rows = VBoxContainer.new()
	_spectator_rows.add_theme_constant_override("separation", 4)
	_spectator_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_spectator_rows)

	_spectator_restart = Button.new()
	_spectator_restart.text = "NUOVA PARTITA"
	_spectator_restart.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	_spectator_restart.add_theme_font_size_override("font_size", 26)
	_spectator_restart.add_theme_color_override("font_color", Style.INK)
	Style.apply_plate(_spectator_restart, Style.GOLD, Style.GOLD_DEEP, 20, 8)
	_spectator_restart.pressed.connect(_start_new_match)
	box.add_child(_spectator_restart)

	var leave := Button.new()
	leave.text = "Torna al menu"
	leave.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	leave.add_theme_font_size_override("font_size", 24)
	Style.apply_plate(leave, Style.PLATE, Style.PLATE_DARK, 16, 5)
	leave.pressed.connect(_on_menu_button_pressed)
	box.add_child(leave)


## Chi è fuori non ha una preparazione da fare: al suo posto la classifica.
## Fuori dai giochi: partita finita o giocatore eliminato. Chi è fuori non ha
## una preparazione da fare, quindi non vede né i pulsanti né la barra del tempo.
func _is_out_of_match() -> bool:
	return match_state.phase == MatchState.Phase.FINISHED or not player().is_alive()


## Unico punto che decide quale delle due schermate si vede — _apply_session_mode_ui()
## delega qui, così non ci sono due posti che accendono e spengono gli stessi
## pulsanti con condizioni diverse.
func _update_spectator_mode() -> void:
	if _spectator_screen == null:
		return
	var finished := match_state.phase == MatchState.Phase.FINISHED
	var out := _is_out_of_match()
	# Durante il replay comanda la battaglia: la classifica riappare quando
	# l'overlay si chiude da solo, e _conclude_round richiama _refresh().
	var show_screen := out and not _combat_overlay.visible
	_spectator_screen.visible = show_screen

	var remote := session_mode == SessionMode.REMOTE
	_fight_button.visible = not remote and not out
	_prep_bar.visible = remote and not out

	if not show_screen:
		return

	if finished:
		_spectator_title.text = "PARTITA CONCLUSA"
		_spectator_subtitle.text = "Il tuo piazzamento: %d° su %d" % [
			player().placement, match_state.players.size()]
		_spectator_status.visible = false
	else:
		_spectator_title.text = "SEI STATO ELIMINATO"
		_spectator_subtitle.text = "%d° posto · tocca un giocatore per rivedere la sua ultima battaglia" % \
			player().placement
		_spectator_status.text = _remaining_players_status_text()
		_spectator_status.visible = true

	# NUOVA PARTITA solo offline e a partita finita (online si rientra in coda
	# dal menu, non da qui).
	_spectator_restart.visible = not remote and finished

	_refresh_spectator_rows()


## Riga di stato dei giocatori ancora in gioco: sono tutti sincronizzati sullo
## stesso round e sulla stessa fase, quindi una sola riga li descrive tutti.
## In preparazione mostra il countdown (in remoto scalato localmente da
## RemoteSession, come il timer del giocatore vivo); in battaglia non c'è un
## timer lato client — la battaglia è un replay — quindi si dice solo la fase.
func _remaining_players_status_text() -> String:
	var alive := 0
	for pl in match_state.players:
		if pl.is_alive():
			alive += 1
	var phase_txt := ""
	match match_state.phase:
		MatchState.Phase.PREPARATION:
			phase_txt = "in preparazione"
			if _session is RemoteSession:
				var left := int(ceil(maxf(0.0, (_session as RemoteSession).prep_seconds_left)))
				phase_txt += " · %d s al via" % left
		MatchState.Phase.COMBAT:
			phase_txt = "in battaglia"
	return "%d giocatori ancora in gioco · Round %s · %s" % [
		alive, match_state.round_label(), phase_txt]


func _refresh_spectator_rows() -> void:
	for child in _spectator_rows.get_children():
		child.queue_free()
	var position := 0
	for pl in match_state.live_ranking():
		position += 1
		_standing_row(_spectator_rows, pl, position, 20)


## Piastra minima per le righe della classifica avversari: trasparente da
## ferma per non appesantire il riquadro, un velo chiaro al passaggio del
## mouse e una faccia incassata da premuta — lo stesso linguaggio di
## Style.apply_plate ma con margini ridotti, perché la riga è alta poche
## decine di pixel e larga 150.
func _style_ranking_row(row: Button, highlight: bool = false) -> void:
	var clear := Style.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 6)
	clear.content_margin_left = 6
	clear.content_margin_right = 6
	clear.content_margin_top = 3
	clear.content_margin_bottom = 3
	# Riga del prossimo avversario: un velo e un bordo color torcia che restano
	# anche da ferma e da spenta (la chip è disabled finché non c'è una battaglia
	# da rivedere), così il segno non sparisce prima del primo combattimento.
	if highlight:
		clear.bg_color = Color(Style.TORCH.r, Style.TORCH.g, Style.TORCH.b, 0.14)
		clear.border_color = Style.TORCH
		clear.set_border_width_all(2)
	var hover := clear.duplicate() as StyleBoxFlat
	if not highlight:
		hover.bg_color = Style.PLATE.lightened(0.06)
		hover.border_color = Style.PLATE.lightened(0.25)
		hover.set_border_width_all(1)
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = Style.PLATE_DARK
	row.add_theme_stylebox_override("normal", clear)
	row.add_theme_stylebox_override("hover", hover)
	row.add_theme_stylebox_override("pressed", pressed)
	row.add_theme_stylebox_override("focus", clear)
	# Anche da spenta, e con la STESSA piastra trasparente: la chip è disabled
	# finché quel giocatore non ha una battaglia da rivedere, cioè per tutto il
	# primo round, e senza questo override Godot ci disegna sopra la piastra
	# scura del tema di serie — otto riquadri neri che a fine prima battaglia
	# sparivano da soli, come se la classifica si accendesse.
	row.add_theme_stylebox_override("disabled", clear)


## Riquadro sinergie sulla schermata principale: una colonna di chip, una per
## tratto presente in squadra. Sta nella colonna a destra della plancia;
## ogni chip è cliccabile e apre il dettaglio dei bonus. Lo sfondo della chip
## (tinta della civiltà / classe se attiva, piastra scura se no) dice a colpo
## d'occhio se la soglia è raggiunta — niente pallino.
func _build_synergy_card() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Style.plate(Style.PLATE, Style.PLATE_DARK, 12, 4))

	_synergy_row = GridContainer.new()
	_synergy_row.columns = 1
	_synergy_row.add_theme_constant_override("h_separation", 6)
	_synergy_row.add_theme_constant_override("v_separation", 6)
	panel.add_child(_synergy_row)

	return panel


## Aggiorna le chip delle sinergie. Vengono ricreate a ogni refresh come la
## classifica avversari: il numero di tratti presenti cambia a ogni mossa, e
## tenerle in sincrono manualmente costerebbe più che rifarle.
func _refresh_synergies() -> void:
	if _synergy_row == null:
		return
	for child in _synergy_row.get_children():
		child.queue_free()

	var rows := TraitResolver.summary(player().board_units())
	if rows.is_empty():
		return

	var any_active := false
	for row in rows:
		_synergy_row.add_child(_synergy_chip(row))
		if bool(row["active"]):
			any_active = true
	if any_active:
		_tips.queue_tip("synergy")


func _synergy_chip(row: Dictionary) -> Button:
	var button := Button.new()
	var progress := "%d" % int(row["count"])
	if int(row["next_threshold"]) > 0:
		progress = "%d/%d" % [int(row["count"]), int(row["next_threshold"])]
	# Il simbolo al posto del nome; nessun pallino di stato — ci pensa lo sfondo.
	# Il nome per esteso resta nel dettaglio (si apre col tocco) e nel tooltip.
	button.text = "%s %s" % [row["symbol"], progress]
	button.tooltip_text = String(row["name"])
	button.add_theme_font_size_override("font_size", 19)
	button.custom_minimum_size = Vector2(0, 44)
	# In griglia a due colonne: entrambe le celle della stessa larghezza, così
	# le chip si allineano invece di seguire la lunghezza del testo.
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var tint: Color = Style.origin_color(String(row["id"])) if bool(row["is_origin"]) else Style.BLUE
	if bool(row["active"]):
		Style.apply_plate(button, tint.darkened(0.55), tint, 12, 4)
		button.add_theme_color_override("font_color", tint.lightened(0.35))
	else:
		Style.apply_plate(button, Style.PLATE_DARK, Style.PLATE, 12, 3)
		button.add_theme_color_override("font_color", Style.TEXT_DIM)

	button.pressed.connect(_open_synergy_detail.bind(String(row["id"])))
	return button


## Pannello di dettaglio di una singola sinergia: tutte le soglie con il
## relativo bonus, quella raggiunta evidenziata in oro. Costruito una sola
## volta e ripopolato a ogni apertura, come il foglio informazioni.
##
## A differenza del foglio informazioni e della battaglia, questo è un
## dettaglio breve: un modale piccolo e centrato, non un pannello a schermo
## intero, con uno sfondo attenuato dietro (gemello, non genitore — così
## resta un semplice rettangolo da mostrare/nascondere insieme al modale,
## senza dover gestire il centraggio anche al suo interno).
func _build_synergy_detail() -> void:
	_synergy_detail_backdrop = ColorRect.new()
	_synergy_detail_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_synergy_detail_backdrop.color = Color(0, 0, 0, 0.55)
	_synergy_detail_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_synergy_detail_backdrop.visible = false
	add_child(_synergy_detail_backdrop)

	# Un CenterContainer a tutto schermo, trasparente e che ignora il mouse
	# fuori dal figlio, tiene il modale in mezzo qualunque sia la sua altezza
	# di contenuto — senza dover calcolare offset a mano come per i pannelli
	# a tutto schermo.
	_synergy_detail = CenterContainer.new()
	_synergy_detail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_synergy_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_synergy_detail.visible = false
	add_child(_synergy_detail)

	var dialog := PanelContainer.new()
	# Più largo di prima: deve ospitare anche la griglia dei modelli delle
	# unità della sinergia, non solo il testo delle soglie.
	dialog.custom_minimum_size = Vector2(560, 0)
	dialog.add_theme_stylebox_override("panel", Style.plate(Style.PLATE, Style.GOLD_DEEP, 18, 6))
	_synergy_detail.add_child(dialog)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	dialog.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	_synergy_detail_title = Label.new()
	_synergy_detail_title.add_theme_font_size_override("font_size", 24)
	_synergy_detail_title.add_theme_color_override("font_color", Style.GOLD)
	_synergy_detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_synergy_detail_title)

	_synergy_detail_description = Label.new()
	_synergy_detail_description.add_theme_font_size_override("font_size", 16)
	_synergy_detail_description.add_theme_color_override("font_color", Style.TEXT_DIM)
	_synergy_detail_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_synergy_detail_description)

	# Altezza limitata invece di SIZE_EXPAND_FILL: dentro un CenterContainer
	# nessun genitore impone un'altezza massima, quindi senza un tetto la
	# lista delle soglie spingerebbe il modale fuori dallo schermo su una
	# sinergia con molti livelli.
	var scroll := ScrollContainer.new()
	# Più alto di prima: ora contiene anche la griglia dei modelli, non solo
	# la lista delle soglie.
	scroll.custom_minimum_size = Vector2(0, 420)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	var scroll_content := VBoxContainer.new()
	scroll_content.add_theme_constant_override("separation", 16)
	scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(scroll_content)

	_synergy_detail_tiers = VBoxContainer.new()
	_synergy_detail_tiers.add_theme_constant_override("separation", 10)
	_synergy_detail_tiers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_content.add_child(_synergy_detail_tiers)

	scroll_content.add_child(_section_title("Unità"))

	_synergy_detail_units = GridContainer.new()
	_synergy_detail_units.columns = 6
	_synergy_detail_units.add_theme_constant_override("h_separation", 6)
	_synergy_detail_units.add_theme_constant_override("v_separation", 6)
	scroll_content.add_child(_synergy_detail_units)

	var close := Button.new()
	close.text = "Chiudi"
	close.custom_minimum_size = Vector2(0, Style.TOUCH_MIN)
	close.add_theme_font_size_override("font_size", 24)
	Style.apply_plate(close, Style.BLUE, Style.BLUE_DEEP, 16, 5)
	close.pressed.connect(_close_synergy_detail)
	column.add_child(close)


func _close_synergy_detail() -> void:
	_synergy_detail.visible = false
	_synergy_detail_backdrop.visible = false


## Popola e apre il dettaglio di una sinergia: tutte le soglie definite in
## traits.json, non solo quella attiva, così si vede anche cosa serve ancora.
## `units` vuoto = la propria squadra (chip di preparazione). In battaglia le
## chip passano la squadra della barra su cui si è cliccato, così le soglie
## mostrate sono quelle davvero raggiunte da quel giocatore.
func _open_synergy_detail(trait_id: String, units: Array = []) -> void:
	var def := GameData.trait_def(trait_id)
	var source: Array = units if not units.is_empty() else player().board_units()
	var count := int(TraitResolver.count_traits(source).get(trait_id, 0))

	_synergy_detail_title.text = String(def.get("name", trait_id))
	_synergy_detail_description.text = String(def.get("description", ""))

	for child in _synergy_detail_tiers.get_children():
		child.queue_free()

	for tier in def.get("tiers", []):
		var required := int(tier["count"])
		var reached := count >= required

		var row := PanelContainer.new()
		if reached:
			row.add_theme_stylebox_override("panel", Style.plate(Style.GOLD_DEEP.darkened(0.35), Style.GOLD, 12, 4))
		else:
			row.add_theme_stylebox_override("panel", Style.plate(Style.PLATE_DARK, Style.PLATE, 12, 3))
		_synergy_detail_tiers.add_child(row)

		var inner := VBoxContainer.new()
		inner.add_theme_constant_override("separation", 4)
		row.add_child(inner)

		var heading := Label.new()
		heading.text = "%d unità %s" % [required, "— raggiunta" if reached else ""]
		heading.add_theme_font_size_override("font_size", 18)
		heading.add_theme_color_override("font_color", Style.GOLD if reached else Style.TEXT_DIM)
		inner.add_child(heading)

		var effect_text := Label.new()
		effect_text.text = String(tier.get("text", ""))
		effect_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		effect_text.add_theme_font_size_override("font_size", 17)
		inner.add_child(effect_text)

	for child in _synergy_detail_units.get_children():
		child.queue_free()

	# Due insiemi distinti: sul campo (verde) o solo in panchina (arancio) —
	# chi ha l'unità in panchina la possiede comunque, anche se al momento
	# non conta per le soglie.
	var board_ids := {}
	for owned in player().board_units():
		board_ids[owned.def.id] = true
	var bench_ids := {}
	for owned in player().bench_units():
		bench_ids[owned.def.id] = true

	for unit_def in GameData.units_with_trait(trait_id):
		var slot := UnitSlot.new()
		slot.custom_minimum_size = SYNERGY_UNIT_SLOT_SIZE
		var fill := Style.PANEL
		var border := Style.rarity_color(unit_def.cost)
		if board_ids.has(unit_def.id):
			fill = Style.OWNED.darkened(0.65)
			border = Style.OWNED
		elif bench_ids.has(unit_def.id):
			fill = Style.OWNED_BENCH.darkened(0.65)
			border = Style.OWNED_BENCH
		slot.show_unit(unit_def, 0, UnitSlot.Badge.NONE, fill, border, 2)
		_synergy_detail_units.add_child(slot)

	_synergy_detail_backdrop.visible = true
	_synergy_detail.visible = true


func _section_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Style.GOLD.darkened(0.2))
	return label


func _spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


# --------------------------------------------------------------------------
# Partita
# --------------------------------------------------------------------------

func _start_new_match() -> void:
	_combat_view.pause()
	_combat_overlay.visible = false
	_spectate_view.pause()
	_spectate_overlay.visible = false
	if _spectator_screen != null:
		_spectator_screen.visible = false
	_pending_results = []
	_auto_close_left = -1.0
	_final_standings = []
	_match_recorded = false
	_fight_button.text = "COMBATTI"
	selected = null

	_session = _make_session()
	_session.begin(_requested_seed(), _profile.effective_hero())
	_session.state_changed.connect(_refresh)
	_session.round_concluded.connect(_on_round_concluded)
	_session.command_rejected.connect(_on_command_rejected)
	_session.spectate_ready.connect(_on_spectate_ready)
	_session.match_finished.connect(_on_match_finished)

	if session_mode == SessionMode.REMOTE:
		_session.round_started.connect(_on_remote_round_started)
		_session.connection_lost.connect(_on_connection_lost)
		_session.rank_updated.connect(_on_rank_updated)

	# Prima di _apply_session_mode_ui(): ora quella legge lo stato per decidere
	# se il giocatore è fuori, e senza match_state non può.
	match_state = _session.state()
	_level_up_pending.clear()
	player().unit_upgraded.connect(_on_unit_upgraded)
	_apply_session_mode_ui()

	_log("[b]Nuova partita[/b] (seed %d)" % match_state.seed_value)
	_log("Civiltà disponibili: %s" % ", ".join(_store.playable_origins()))
	_restart_preparation_timer()
	_refresh()
	_tips.queue_tip("shop")


## Crea la sessione adatta alla modalità corrente. Il single-player usa sempre
## LocalSession; RemoteSession è lo scheletro che si completa in M6.
func _make_session() -> MatchSession:
	# La lobby consegna una RemoteSession gia' agganciata al worker tramite un
	# meta sulla radice (handoff senza autoload). Consumato subito.
	var tree_root := get_tree().root
	if tree_root.has_meta("pending_session"):
		var handed: Variant = tree_root.get_meta("pending_session")
		tree_root.remove_meta("pending_session")
		if handed is RemoteSession:
			session_mode = SessionMode.REMOTE
			var remote := handed as RemoteSession
			remote.drive(self)
			return remote
	session_mode = SessionMode.LOCAL
	return LocalSession.new()


## Nasconde/mostra i comandi in base alla modalità: in remoto niente COMBATTI,
## c'è PRONTO + countdown; in locale il contrario. Delega a
## _update_spectator_mode(), che è l'unico posto che decide la visibilità dei
## due pulsanti — un eliminato non deve vedere né l'uno né l'altro.
func _apply_session_mode_ui() -> void:
	_update_spectator_mode()


func _on_ready_pressed() -> void:
	if _combat_overlay.visible:
		return
	_ready_button.disabled = true
	_ready_button.text = "IN ATTESA…"
	_session.request_ready()


## Il server ha aperto il round successivo: tutte le battaglie del round sono
## finite, quindi è il momento in cui gli otto rientrano insieme in preparazione.
func _on_remote_round_started(_stage: int, _round_index: int) -> void:
	_ready_button.disabled = false
	_ready_button.text = "PRONTO"
	_request_overlay_close(true)


func _process(delta: float) -> void:
	# Prima del guard sulla modalità: l'uscita automatica dalla battaglia vale
	# anche in locale. Tenere qui solo questo, il resto della funzione è remoto.
	if _auto_close_left >= 0.0:
		_auto_close_left -= delta
		if _auto_close_left <= 0.0:
			_close_combat_overlay()

	_tick_combat_bar(delta)
	_tick_preparation(delta)
	_update_match_music()

	# Countdown fluido della riga di stato per chi guarda da eliminato: senza
	# questo si aggiornerebbe solo a ogni snapshot del server.
	if _spectator_status != null and _spectator_status.visible \
			and match_state.phase != MatchState.Phase.FINISHED:
		_spectator_status.text = _remaining_players_status_text()

	if session_mode != SessionMode.REMOTE or _prep_label == null:
		return
	if _session is RemoteSession and not _combat_overlay.visible:
		var left: float = (_session as RemoteSession).prep_seconds_left
		_prep_label.text = "Preparazione: %d s" % int(ceil(maxf(0.0, left)))


## La barra della battaglia avanza sull'orologio reale, non su quello della
## riproduzione: quando la propria battaglia finisce prima del limite continua
## a scorrere mentre si aspettano gli altri scontri, e si ferma da sé al limite
## del round. È il senso della barra — dice quanto dura il round, non quanto
## dura la propria battaglia.
func _tick_combat_bar(delta: float) -> void:
	if _combat_bar == null or not _combat_overlay.visible:
		return
	_combat_bar_elapsed += delta
	_combat_bar.set_elapsed(_combat_bar_elapsed)


## Conto alla rovescia della preparazione. In remoto il tempo è del server e la
## barra si limita a rispecchiarlo; in locale lo teniamo qui e allo scadere si
## fa partire il round come se fosse stato premuto COMBATTI.
func _tick_preparation(delta: float) -> void:
	if _prep_phase_bar == null:
		return

	var running := not _combat_overlay.visible \
		and match_state.phase == MatchState.Phase.PREPARATION \
		and not _is_out_of_match()
	_prep_phase_bar.visible = running
	if not running:
		_last_prep_beep = -1
		return

	var seconds_left: float = (_session as RemoteSession).prep_seconds_left \
		if _session is RemoteSession else _prep_left
	_prep_countdown_beep(seconds_left)

	if _session is RemoteSession:
		var total := _prep_phase_bar.total
		_prep_phase_bar.set_elapsed(total - (_session as RemoteSession).prep_seconds_left)
		return

	if _prep_left < 0.0:
		return
	_prep_left -= delta
	_prep_phase_bar.set_elapsed(_prep_phase_bar.total - _prep_left)
	if _prep_left <= 0.0:
		# Disarmato prima di risolvere: request_ready() è sincrona in locale e
		# porta dritti alla battaglia, che riarmerà il conto alla rovescia da
		# _close_combat_overlay(). Senza questo si rientrerebbe qui il frame dopo.
		_prep_left = -1.0
		_session.request_ready()


## Sceglie la traccia in base allo stato della partita: battaglia mentre l'overlay
## di combattimento è visibile (anche da spettatore eliminato), preparazione
## durante il conto alla rovescia, altrimenti il tema generale (risultati, lobby
## interna). play_track() ignora la ripetizione, quindi si può chiamare a ogni frame.
func _update_match_music() -> void:
	var music := get_node_or_null("/root/Music")
	if music == null:
		return
	if _combat_overlay.visible:
		music.play_battle()
	elif match_state.phase == MatchState.Phase.PREPARATION and not _is_out_of_match():
		music.play_prep()
	else:
		music.play_general()


## Un bip al secondo negli ultimi 10 secondi di preparazione, in locale e in
## remoto. Deduplica sul secondo intero: _tick_preparation gira a ogni frame,
## il suono deve scattare una volta sola per secondo.
func _prep_countdown_beep(seconds_left: float) -> void:
	if seconds_left <= 0.0 or seconds_left > 10.0:
		_last_prep_beep = -1
		return
	var whole := int(ceil(seconds_left))
	if whole == _last_prep_beep:
		return
	_last_prep_beep = whole
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null:
		sfx.play("countdown")


## Riarma il conto alla rovescia della preparazione all'inizio di ogni round.
## Il primo round e i successivi possono durare diversamente (data/balance.json),
## quindi la durata si rilegge ogni volta invece di essere memorizzata.
func _restart_preparation_timer() -> void:
	if _prep_phase_bar == null:
		return
	var rounds: Dictionary = GameData.balance()["rounds"]
	var first := match_state.stage <= 1 and match_state.round_index <= 1
	var total := float(rounds["first_round_preparation_seconds"] if first else rounds["preparation_seconds"])
	_prep_phase_bar.configure(total)
	_last_prep_beep = -1
	# In remoto il countdown è quello del server: la barra lo rispecchia e basta.
	_prep_left = -1.0 if _session is RemoteSession else total


## La connessione col worker è caduta: pannello modale con riconnessione manuale
## come fallback (RemoteSession tenta comunque la riconnessione automatica).
func _on_connection_lost(_reason: String) -> void:
	if _reconnect_panel == null:
		_build_reconnect_panel()
	_reconnect_panel.visible = true


func _build_reconnect_panel() -> void:
	_reconnect_panel = Panel.new()
	_reconnect_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_reconnect_panel.add_theme_stylebox_override("panel", Style.box(Color(0.02, 0.03, 0.07, 0.94), Color(0.02, 0.03, 0.07, 0.94), 0, 0))
	_reconnect_panel.visible = false
	add_child(_reconnect_panel)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_reconnect_panel.add_child(center)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	center.add_child(column)

	var label := Label.new()
	label.text = "Connessione persa — riconnessione…"
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Style.GOLD)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(label)

	var retry := Button.new()
	retry.text = "Riconnetti"
	retry.custom_minimum_size = Vector2(260, Style.TOUCH_MIN)
	retry.add_theme_font_size_override("font_size", 22)
	Style.apply_plate(retry, Style.GOLD, Style.GOLD_DEEP, 18, 6)
	retry.add_theme_color_override("font_color", Style.INK)
	retry.pressed.connect(func() -> void:
		_reconnect_panel.visible = false
		if _session is RemoteSession:
			(_session as RemoteSession).reconnect())
	column.add_child(retry)

	var to_menu := Button.new()
	to_menu.text = "Torna al menu"
	to_menu.custom_minimum_size = Vector2(260, Style.TOUCH_MIN)
	to_menu.add_theme_font_size_override("font_size", 22)
	Style.apply_plate(to_menu, Style.BLUE, Style.BLUE_DEEP, 18, 6)
	to_menu.pressed.connect(_on_menu_pressed)
	column.add_child(to_menu)


func _on_fight_pressed() -> void:
	if _combat_overlay.visible:
		return
	if match_state.phase == MatchState.Phase.FINISHED:
		_start_new_match()
		return

	_session.request_ready()


## La sessione ha risolto il round. Il giocatore vede il replay se c'è qualcosa
## da guardare, altrimenti si passa dritti alla conclusione. La sessione ha già
## fatto avanzare lo stato (e, se la partita continua, aperto il round dopo):
## qui si decide solo cosa mostrare.
func _on_round_concluded(results: Array) -> void:
	var own := _own_result(results)

	# Niente replay se non c'è nulla da guardare: giocatore già eliminato,
	# round senza avversario, o due schieramenti vuoti.
	if own.is_empty() or own["combat"].is_empty() or own["combat"]["initial"].is_empty():
		_conclude_round(results)
		return

	_pending_results = results
	_show_combat(own)


## Un comando è stato rifiutato dalla sessione: si racconta perché, con lo
## stesso testo che prima era in linea nei gestori dei pulsanti.
func _on_command_rejected(reason: String) -> void:
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null:
		sfx.play_denied()
	match reason:
		"reroll":
			_log("[color=#e0a070]Oro insufficiente per aggiornare il negozio.[/color]")
		"buy_xp":
			_log("[color=#e0a070]Non puoi comprare esperienza adesso.[/color]")
		"board_full":
			var p := player()
			_log("[color=#e0a070]Puoi schierare al massimo %d unità (livello %d).[/color]" % [p.max_board_units(), p.level])
		# Motivi dal server autoritativo (modalità remota).
		"phase":
			_log("[color=#e0a070]Non puoi farlo adesso: la fase di preparazione è chiusa.[/color]")
		"rules":
			_log("[color=#e0a070]Mossa non consentita.[/color]")
		"identity":
			_log("[color=#e0a070]Comando rifiutato dal server.[/color]")
		"eliminated":
			_log("[color=#e0a070]Sei stato eliminato: non puoi più comprare né aggiornare.[/color]")
		"not_joined", "no_match", "join_token", "join_seat":
			_log("[color=#e0a070]Sessione non valida — prova a riconnetterti.[/color]")
		"oversize":
			_log("[color=#e0a070]Comando troppo grande, ignorato.[/color]")
		_:
			_log("[color=#e0a070]Comando rifiutato (%s).[/color]" % reason)


## Il risultato del round dal punto di vista del giocatore umano.
func _own_result(results: Array) -> Dictionary:
	for result in results:
		if result["player"] == player():
			return result
	return {}


func _show_combat(own: Dictionary) -> void:
	var opponent: Player = own["opponent"]
	_combat_title.text = "Round %s — contro %s" % [
		_previous_round_label(), opponent.display_name if opponent != null else "nessuno",
	]
	_refresh_combat_info(own)
	_combat_outcome.text = ""
	_combat_hint.visible = false
	_combat_controls.visible = true
	_auto_close_left = -1.0

	var combat: Dictionary = GameData.balance()["combat"]
	_combat_bar.configure(
		float(combat["max_duration_seconds"]),
		float(own["combat"].get("berserk_at", combat["berserk_at_seconds"]))
	)
	_combat_bar_elapsed = 0.0

	# La propria battaglia si guarda sempre a velocità reale: è la barra a dire
	# quanto dura il round, e un moltiplicatore la smentirebbe. L'accelerazione
	# che si vede negli ultimi secondi è dentro il log, non nella riproduzione.
	_combat_view.speed = 1.0
	_combat_view.set_hero_portraits(player().hero_id, opponent.hero_id if opponent != null else "")
	_combat_view.load_combat(own["combat"], int(own.get("team", 0)))
	_combat_overlay.visible = true
	_combat_view.play()


## resolve_round() ha già fatto avanzare il contatore, quindi la battaglia
## appena combattuta è quella del round precedente.
func _previous_round_label() -> String:
	var rounds_per_stage := int(GameData.balance()["rounds"]["rounds_per_stage"])
	var index := match_state.round_index - 1
	var stage := match_state.stage
	if index < 1:
		index = rounds_per_stage
		stage -= 1
	return "%d-%d" % [stage, index]


func _on_playback_finished() -> void:
	var own := _own_result(_pending_results)
	if own.is_empty():
		_close_combat_overlay()
		return

	if bool(own["won"]):
		_combat_outcome.text = "Vittoria — %d danni all'avversario" % int(own["damage_dealt"])
		_combat_outcome.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5))
	else:
		_combat_outcome.text = "Sconfitta — %d danni alla tua vita" % int(own["damage"])
		_combat_outcome.add_theme_color_override("font_color", Color(0.9, 0.45, 0.45))
	_combat_hint.visible = true
	_combat_controls.visible = false
	_tips.queue_tip("combat")
	# Vista la prima battaglia, il giocatore ha un motivo concreto per aprire il
	# riquadro CLASSIFICA: spiegargli che le righe sono toccabili.
	_tips.queue_tip("ranking")
	if own.get("opponent") != null and not bool(own.get("ghost", false)):
		_combat_view.show_result_beam(bool(own["won"]), int(own["damage_dealt"] if bool(own["won"]) else own["damage"]))

	# In locale il ritmo lo detta il client: LocalSession.request_ready() è
	# sincrona e ha già risolto e riaperto il round, quindi si esce appena il
	# fascio del risultato ha finito. In remoto il ritmo è del server e si
	# aspetta ROUND_STARTED, così gli otto rientrano insieme — a meno che la
	# partita sia finita, e allora un altro round non arriverà mai.
	if session_mode == SessionMode.LOCAL or not _final_standings.is_empty():
		_request_overlay_close(false)


## L'unico modo di lasciare la schermata di battaglia: non c'è più un pulsante.
func _close_combat_overlay() -> void:
	_auto_close_left = -1.0
	if not _combat_overlay.visible:
		return
	_combat_view.pause()
	_combat_overlay.visible = false
	var results := _pending_results
	_pending_results = []
	_conclude_round(results)


## Chiede l'uscita dalla battaglia. `immediate` = le battaglie del round sono
## finite tutte e il round dopo è già aperto (in remoto lo dice il server): si
## esce subito. Altrimenti si lascia il tempo di vedere il fascio e leggere
## l'esito prima di sparire.
func _request_overlay_close(immediate: bool) -> void:
	if not _combat_overlay.visible:
		return
	if immediate:
		_close_combat_overlay()
	else:
		_auto_close_left = result_pause


## Chiude il round: racconto dell'esito, preparazione del successivo.
func _conclude_round(results: Array) -> void:
	_report(results)

	if match_state.phase == MatchState.Phase.FINISHED or not _final_standings.is_empty():
		_show_match_over()
	else:
		# round_index è già stato fatto avanzare da resolve_round(): stage 1,
		# round 2 è il primo round che il giocatore sta per affrontare dopo
		# aver visto un round intero di economia in azione.
		# Il round successivo l'ha già aperto la sessione (in remoto lo fa il
		# server): qui resta solo il suggerimento sull'economia.
		if match_state.stage == 1 and match_state.round_index == 2:
			_tips.queue_tip("economy")
	# Unico punto in cui riparte il conto alla rovescia della preparazione: ci
	# si passa sia uscendo dal replay sia quando non c'era nulla da guardare.
	_restart_preparation_timer()
	_refresh()


## La partita è decisa. Il segnale arriva PRIMA del replay in locale
## (LocalSession.request_ready è sincrona) e può arrivare mentre il replay è in
## corso in remoto: in nessuno dei due casi l'esito si racconta qui, o si
## svelerebbe il risultato mentre lo si sta guardando. Si annota e basta; a
## dirlo sarà _conclude_round(), a battaglia finita.
func _on_match_finished(standings: Array) -> void:
	_final_standings = _normalize_standings(standings)
	if _combat_overlay.visible:
		_request_overlay_close(false)
		return
	_show_match_over()


## Le due sessioni mandano forme diverse: LocalSession un Array[Player],
## RemoteSession un Array[Dictionary] (server/match_runner._standings_data).
## La UI ne vuole una sola.
func _normalize_standings(standings: Array) -> Array:
	var out: Array = []
	for entry in standings:
		if entry is Player:
			var p := entry as Player
			out.append({
				"player_index": p.index, "display_name": p.display_name,
				"placement": p.placement, "hp": p.hp,
			})
		elif entry is Dictionary:
			out.append(entry)
	return out


func _show_match_over() -> void:
	if _final_standings.is_empty():
		_final_standings = _normalize_standings(match_state.standings())
	if not _final_standings.is_empty():
		_log("\n[b]Partita conclusa.[/b] Vince %s." % _final_standings[0].get("display_name", "?"))
	_log("Il tuo piazzamento: %d° su %d." % [player().placement, match_state.players.size()])
	_fight_button.text = "NUOVA PARTITA"
	# record_match una volta sola: _conclude_round può ripassare di qui se
	# arrivano altri snapshot dopo la fine.
	if not _match_recorded:
		_match_recorded = true
		_profile.record_match(player().placement, session_mode == SessionMode.REMOTE)
		_record_local_history()
	if session_mode == SessionMode.REMOTE:
		_ready_button.visible = false
		_prep_label.text = "Partita conclusa — usa ☰ per uscire"


## Cronologia e telemetria delle partite locali (app/match_log.gd). Solo in
## locale: online le scrive il server, che e' l'unico a vedere tutte le
## formazioni, e la cronologia arriva dal DB. Agganciato al medesimo guardiano
## di record_match(), quindi una partita non puo' finire due volte nel file.
func _record_local_history() -> void:
	if session_mode != SessionMode.LOCAL:
		return
	var telemetry := _session.telemetry() if _session != null else null
	MatchLog.append_match({
		"mode": "cpu",
		"placement": player().placement,
		"players": match_state.players.size(),
		"hp": player().hp,
		"hero_id": player().hero_id,
		"seed": match_state.seed_value,
		"rounds": telemetry.match_rounds() if telemetry != null else 0,
		"units": _final_units(),
	})
	if telemetry != null:
		MatchLog.append_telemetry(telemetry.report_dict({"seed": match_state.seed_value}))


## La formazione con cui il giocatore locale ha chiuso, nella stessa forma che
## il server manda per le partite online (unit_id + stella): cosi' HistoryPanel
## legge le due sorgenti con lo stesso codice.
func _final_units() -> Array:
	var out: Array = []
	for inst in player().board_units():
		out.append({"unit_id": inst.def.id, "final_star": inst.star})
	return out


## L'mmr arriva in ritardo rispetto a MATCH_FINISHED (RANK_UPDATE — vedi
## net/remote_session.gd), quasi sempre quando la schermata di fine partita è
## già a video: si limita ad aggiungere una riga al log, non a ridisegnare
## nulla. Auth.stats è già aggiornato a questo punto (lo fa RemoteSession),
## cosa che serve al menu, non a questa schermata.
func _on_rank_updated(mmr: int, delta: int) -> void:
	var rank := GameData.rank_for_mmr(mmr)
	var sign := "+" if delta >= 0 else ""
	_log("Grado: %s (%d mmr, %s%d)" % [rank.get("name", "—"), mmr, sign, delta])


## Chiede conferma prima di lasciare il combattimento: uscire abbandona la
## partita in corso (il cambio di scena la distrugge), quindi un tocco per
## sbaglio sul menu non deve poter buttare via un round già in corso.
func _on_menu_button_pressed() -> void:
	# Una modale nuova a ogni apertura: ModalDialog si libera da sola alla
	# risposta, quindi non c'è niente da tenere in un campo.
	var dialog: ModalDialog
	if not _final_standings.is_empty():
		# La partita per il giocatore è già finita (è nella schermata della
		# classifica): uscire non è una resa, non cambia nulla del risultato.
		dialog = ModalDialog.confirm(self, "Uscire dalla partita?",
			"Vuoi tornare al menu?",
			"Esci")
	elif session_mode == SessionMode.REMOTE:
		# Online non si può distruggere la scena e sparire: è una resa.
		dialog = ModalDialog.confirm(self, "Abbandonare la partita?",
			"La partita verrà contata come una sconfitta e il posto in classifica ne risentirà.",
			"Abbandona")
	else:
		dialog = ModalDialog.confirm(self, "Uscire dal combattimento?",
			"La partita in corso andrà persa: non è possibile riprenderla da dove l'hai lasciata.",
			"Esci")
	dialog.confirmed.connect(_on_exit_confirmed)


func _on_exit_confirmed() -> void:
	if session_mode == SessionMode.REMOTE and _session != null and _final_standings.is_empty():
		_session.leave()  # invia SURRENDER
	_on_menu_pressed()


## Torna alla schermata iniziale. La partita in corso viene abbandonata: il
## cambio di scena la distrugge, e questo è il motivo per cui il menu è una
## scena separata invece di un pannello sovrapposto.
func _on_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://ui/menu.tscn")


## Mostra l'esito del round dal punto di vista del giocatore umano, più un
## riepilogo di chi è ancora in gioco.
func _report(results: Array) -> void:
	var human := player()
	_log("\n[b]Round %s[/b]" % match_state.round_label())

	for result in results:
		if result["player"] != human:
			continue
		var opponent: Player = result["opponent"]
		var opponent_name: String = opponent.display_name if opponent != null else "nessuno"
		if bool(result["won"]):
			_log("  [color=#7fd67f]Vittoria[/color] contro %s (−%d vita avversario)" % [opponent_name, int(result["damage_dealt"])])
		else:
			_log("  [color=#e07070]Sconfitta[/color] contro %s (−%d vita)" % [opponent_name, int(result["damage"])])
		var combat: Dictionary = result["combat"]
		if not combat.is_empty():
			_log("  durata %.1fs" % float(combat["duration"]))

	if human.eliminated:
		_log("  [color=#e07070]Sei stato eliminato: %d° posto.[/color]" % human.placement)

	_log("  in gioco: %d" % match_state.alive_players().size())


func _on_reroll_pressed() -> void:
	_session.request_reroll()


func _on_buy_xp_pressed() -> void:
	_session.request_buy_xp()


func _on_sell_pressed() -> void:
	if selected == null:
		return
	var value := selected.sell_value()
	var name := selected.def.display_name
	_session.request_sell(selected.uid)
	selected = null
	_log("Venduto %s per %d oro." % [name, value])


func _on_shop_slot_pressed(slot: int) -> void:
	var p := player()
	if p.shop[slot] == null:
		return
	if not p.can_buy(slot):
		var sfx := get_node_or_null("/root/Sfx")
		if sfx != null:
			sfx.play_denied()
		var def: UnitDef = p.shop[slot]
		if p.gold < def.cost:
			_log("[color=#e0a070]Servono %d oro per %s.[/color]" % [def.cost, def.display_name])
		else:
			_log("[color=#e0a070]Panchina piena.[/color]")
		return
	var bought_name: String = (p.shop[slot] as UnitDef).display_name
	_session.request_buy(slot)
	_log("Comprato %s." % bought_name)
	_tips.queue_tip("bench")


## Un clic su una cella: se c'è un'unità selezionata la sposta, altrimenti
## seleziona quella presente.
func _on_cell_pressed(cell: Vector2i) -> void:
	var p := player()
	if selected != null:
		_session.request_move_to_board(selected.uid, cell)
		selected = null
	else:
		selected = p.unit_at_cell(cell)
	_refresh()


func _on_bench_slot_pressed(slot: int) -> void:
	var p := player()
	var occupant: UnitInstance = null
	for unit in p.bench_units():
		if unit.bench_slot == slot:
			occupant = unit
			break

	if selected != null:
		_session.request_move_to_bench(selected.uid, slot)
		selected = null
	else:
		selected = occupant
		if selected != null:
			_tips.queue_tip("board")
	_refresh()


# --------------------------------------------------------------------------
# Aggiornamento della vista
# --------------------------------------------------------------------------

## Oro bonus che la serie corrente darà a fine round, mostrato di fianco al
## contatore così il giocatore capisce a cosa serve. Stessa logica di
## Player.grant_round_income (economy.streak_thresholds), sul valore assoluto:
## anche una serie di sconfitte rende.
func _streak_gold_bonus(streak: int) -> int:
	var bonus := 0
	for threshold in GameData.balance()["economy"]["streak_thresholds"]:
		if absi(streak) >= int(threshold["streak"]):
			bonus = int(threshold["gold"])
	return bonus


func _refresh() -> void:
	# Uno snapshot dal server significa che la connessione regge: via il pannello.
	if _reconnect_panel != null and _reconnect_panel.visible:
		_reconnect_panel.visible = false

	var p := player()

	_round_label.text = "Round %s" % match_state.round_label()

	# I tre numeri caldi finiscono nelle chip, dove si leggono di sbieco senza
	# rileggere l'etichetta; quelli che si consultano e basta restano in riga.
	_hp_label.text = str(p.hp)
	_gold_label.text = str(p.gold)
	_level_label.text = "%d  (%d/%d)" % [p.level, p.xp, p.xp_to_next_level()]
	_rank_label.text = "%d°" % match_state.rank_of(p)
	# "Unità X/Y" in rosso e grassetto finché il giocatore schiera meno unità di
	# quante potrebbe: è l'unico posto che dice quanti personaggi può mettere in
	# campo, e va notato mentre la panchina è ancora piena.
	var deployed := p.board_count()
	var cap := p.max_board_units()
	var units_text := "Unità %d/%d" % [deployed, cap]
	if deployed < cap:
		units_text = "[b][color=#e87272]%s[/color][/b]" % units_text
	var streak_text := "Serie %+d" % p.streak
	var streak_gold := _streak_gold_bonus(p.streak)
	if streak_gold > 0:
		streak_text += " (+%d oro)" % streak_gold
	_stats_label.text = "%s    %s    %s" % [p.display_name, units_text, streak_text]

	_sell_button.disabled = selected == null
	_sell_button.text = "Vendi · %d" % selected.sell_value() if selected != null else "Vendi"

	_refresh_shop()
	_refresh_board()
	_refresh_bench()
	_refresh_synergies()
	_refresh_ranking()
	# Ultimo: legge i dati che i refresh sopra hanno appena aggiornato, e decide
	# se coprire tutto con la classifica.
	_update_spectator_mode()

	for unit in p.board_units() + p.bench_units():
		if unit.star >= 2:
			_tips.queue_tip("star")
			break


## --- Drag & drop delle unità ----------------------------------------------
## Alternativa al "tocca per selezionare, tocca per posizionare": si trascina
## l'unità dalla panchina al campo, dal campo alla panchina o tra celle del
## campo. Il rilascio chiama gli stessi request_move_* del tocco, che gestiscono
## già lo scambio con l'eventuale occupante.

## Cosa parte da questa casella. null = niente da trascinare (negozio, casella
## vuota, fuori dalla preparazione, giocatore eliminato).
func slot_drag_data(slot: UnitSlot) -> Variant:
	if _combat_overlay.visible or match_state.phase != MatchState.Phase.PREPARATION:
		return null
	if _is_out_of_match() or slot.zone == UnitSlot.Zone.SHOP:
		return null
	var unit := _slot_unit(slot)
	if unit == null:
		return null
	selected = unit
	_refresh()
	return {"uid": unit.uid}


## Si può rilasciare su qualsiasi cella del campo o slot della panchina (anche
## occupati: sarà uno scambio). Non sul negozio.
func slot_can_drop(slot: UnitSlot, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY or not data.has("uid"):
		return false
	return slot.zone == UnitSlot.Zone.BOARD or slot.zone == UnitSlot.Zone.BENCH


func slot_drop(slot: UnitSlot, data: Variant) -> void:
	var uid := int(data["uid"])
	match slot.zone:
		UnitSlot.Zone.BOARD:
			_session.request_move_to_board(uid, slot.slot_key as Vector2i)
		UnitSlot.Zone.BENCH:
			_session.request_move_to_bench(uid, int(slot.slot_key))
	selected = null
	_refresh()


## L'unità che occupa la casella, o null.
func _slot_unit(slot: UnitSlot) -> UnitInstance:
	var p := player()
	match slot.zone:
		UnitSlot.Zone.BOARD:
			return p.unit_at_cell(slot.slot_key as Vector2i)
		UnitSlot.Zone.BENCH:
			for unit in p.bench_units():
				if unit.bench_slot == int(slot.slot_key):
					return unit
	return null


## Crea i controlli a numero fisso. Chiamata una sola volta, da _ready().
func _build_slot_buttons() -> void:
	var match_data: Dictionary = GameData.balance()["match"]

	for slot in int(match_data["shop_slots"]):
		var button := UnitSlot.new()
		button.custom_minimum_size = SHOP_SLOT_SIZE
		button.zone = UnitSlot.Zone.SHOP
		button.slot_key = slot
		button.drag_agent = self
		button.pressed.connect(_on_shop_slot_pressed.bind(slot))
		_shop_row.add_child(button)
		_shop_buttons.append(button)

	for y in int(match_data["board_rows"]):
		var row_box := HBoxContainer.new()
		row_box.add_theme_constant_override("separation", 0)
		_board_rows.add_child(row_box)
		# Lo sfalsamento delle righe dispari è uno spaziatore di mezza cella in
		# testa alla riga: le celle restano pulsanti normali, e resta il layout a
		# occuparsi delle dimensioni.
		if y % 2 == 1:
			var offset := Control.new()
			offset.custom_minimum_size = Vector2(CELL_SIZE.x * 0.5, 0)
			offset.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row_box.add_child(offset)
			_row_offsets.append(offset)
		for x in int(match_data["board_columns"]):
			var cell := Vector2i(x, y)
			var button := UnitSlot.new()
			button.hexagonal = true
			button.custom_minimum_size = CELL_SIZE
			button.zone = UnitSlot.Zone.BOARD
			button.slot_key = cell
			button.drag_agent = self
			button.pressed.connect(_on_cell_pressed.bind(cell))
			row_box.add_child(button)
			_cell_buttons[cell] = button

	for slot in int(match_data["bench_size"]):
		var button := UnitSlot.new()
		button.custom_minimum_size = BENCH_SLOT_SIZE
		button.zone = UnitSlot.Zone.BENCH
		button.slot_key = slot
		button.drag_agent = self
		button.pressed.connect(_on_bench_slot_pressed.bind(slot))
		_bench_row.add_child(button)
		_bench_buttons.append(button)

	# I ritratti si preparano subito: generarli mentre il giocatore compra
	# farebbe comparire le figure a scoppio ritardato.
	get_node("/root/Portraits").preload_units(_all_unit_ids())


# --------------------------------------------------------------------------
# Adattamento allo schermo
# --------------------------------------------------------------------------

## Riscrive la dimensione di caselle, spaziatori e pulsanti icona in base allo
## spazio che c'è davvero, invece di lasciarne trecento pixel vuoti in fondo
## allo scroll come farebbero tre costanti.
func _apply_metrics() -> void:
	if _board_rows == null or _cell_buttons.is_empty():
		return

	# Si aspettano due fotogrammi prima di misurare, ed è la parte fragile di
	# questa funzione. L'altezza minima dichiarata da un HFlowContainer prima di
	# avere una larghezza è quella del caso peggiore, con tutti i figli
	# incolonnati: le sinergie e la striscia avversari si dichiarano insieme
	# alte quasi settecento pixel invece di un centinaio, e lo stesso fa una
	# Label con autowrap, che a larghezza zero va a capo a ogni lettera. Misurato
	# troppo presto, il calcolo conclude sempre che non c'è spazio per crescere.
	# Un fotogramma non basta: al primo il layout assegna le larghezze, al
	# secondo i contenitori a flusso hanno rifatto i conti.
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return

	_slot_scale = _slot_scales()
	var cell := (CELL_SIZE * _slot_scale.x).floor()
	var bench := (BENCH_SLOT_SIZE * _slot_scale.y).floor()
	var shop := (SHOP_SLOT_SIZE * _slot_scale.z).floor()

	for key in _cell_buttons:
		(_cell_buttons[key] as UnitSlot).custom_minimum_size = cell
	# Lo sfalsamento è metà cella: se cresce la casella e non lo spaziatore, le
	# righe dispari smettono di incastrarsi con quelle pari.
	for offset in _row_offsets:
		offset.custom_minimum_size = Vector2(cell.x * 0.5, 0)
	_board_rows.add_theme_constant_override("separation", int(-cell.y * BOARD_OVERLAP))

	for button in _bench_buttons:
		button.custom_minimum_size = bench
	for button in _shop_buttons:
		button.custom_minimum_size = shop

	# I due pulsanti icona pareggiano l'altezza della fila accanto: uno da 56 px
	# a fianco di caselle da 120 sembrerebbe dimenticato lì.
	if _xp_button != null:
		_xp_button.custom_minimum_size = Vector2(ICON_BUTTON_SIZE.x, bench.y)
	if _reroll_button != null:
		_reroll_button.custom_minimum_size = Vector2(ICON_BUTTON_SIZE.x, shop.y)


## Il fattore di ingrandimento di plancia (x), panchina (y) e negozio (z).
##
## Ogni zona ha un suo tetto di larghezza — la plancia può crescere molto di più
## delle altre due, che devono lasciare posto al pulsante icona — mentre il
## vincolo di altezza è uno solo e condiviso: il corpo non deve superare
## l'altezza dello scroll. Si cerca quindi per bisezione il più grande fattore
## comune che rispetta l'altezza, e ogni zona lo usa fino al proprio tetto.
##
## Il risultato non scende mai sotto 1.0: dove non avanza spazio la schermata
## resta quella di prima, scroll compreso.
func _slot_scales() -> Vector3:
	var canvas := get_viewport_rect().size
	var available_width := canvas.x - SIDE_MARGIN * 2.0
	var available_height := _scroll_height(canvas)
	if available_width <= 0.0 or available_height <= 0.0:
		return Vector3.ONE  # headless, o prima che il viewport abbia una misura

	var match_data: Dictionary = GameData.balance()["match"]
	var columns := float(match_data["board_columns"])
	var bench_slots := float(match_data["bench_size"])
	var shop_slots := float(match_data["shop_slots"])

	# Tetti di larghezza. La plancia conta mezza colonna in più per lo
	# sfalsamento delle righe dispari e sconta la colonna delle sinergie che
	# le sta a fianco; le altre due scontano il pulsante icona e le separazioni
	# fra le caselle (4 px in panchina, 6 nel negozio).
	var caps := Vector3(
		(available_width - SYNERGY_COL_WIDTH - SYNERGY_COL_GAP)
			/ (CELL_SIZE.x * (columns + 0.5)),
		(available_width - ICON_BUTTON_SIZE.x - 6.0 - 4.0 * (bench_slots - 1.0))
			/ (BENCH_SLOT_SIZE.x * bench_slots),
		(available_width - ICON_BUTTON_SIZE.x - 6.0 - 6.0 * (shop_slots - 1.0))
			/ (SHOP_SLOT_SIZE.x * shop_slots))
	caps = caps.clamp(Vector3.ONE, Vector3.ONE * MAX_SLOT_SCALE)

	# La parte del corpo che NON dipende dal fattore: titoli, spaziatori,
	# sinergie, striscia avversari, separazioni. Si ricava per differenza dalla
	# misura attuale invece di riscriverla a mano — così resta giusta anche
	# quando le chip vanno a capo o un titolo si spezza su due righe.
	var fixed := _body.get_combined_minimum_size().y - _scalable_height(_slot_scale)

	var low := 1.0
	var high := MAX_SLOT_SCALE
	for _i in 24:
		var mid := (low + high) * 0.5
		if fixed + _scalable_height(caps.min(Vector3.ONE * mid)) <= available_height:
			low = mid
		else:
			high = mid
	return caps.min(Vector3.ONE * low)


## Altezza delle tre zone che scalano, dato un fattore per ciascuna.
func _scalable_height(scale: Vector3) -> float:
	var rows := float(GameData.balance()["match"]["board_rows"])
	# Con la sovrapposizione, n righe alte h occupano h * (n - 0.25*(n-1)).
	var board := CELL_SIZE.y * scale.x * (rows - BOARD_OVERLAP * (rows - 1.0))
	return board + BENCH_SLOT_SIZE.y * scale.y + SHOP_SLOT_SIZE.y * scale.z


## Quanto spazio verticale resta al corpo che scorre: la tela meno i margini,
## meno le barre che non scorrono (stato in cima, comandi in fondo, bolla dei
## suggerimenti in mezzo) e le separazioni fra loro.
func _scroll_height(canvas: Vector2) -> float:
	if _root_column == null or _scroll == null:
		return 0.0
	var height := canvas.y - TOP_MARGIN - BOTTOM_MARGIN
	var children := _root_column.get_child_count()
	height -= ROOT_SEPARATION * maxf(0.0, float(children) - 1.0)
	for child in _root_column.get_children():
		if child != _scroll:
			height -= (child as Control).get_combined_minimum_size().y
	return height - CONTENT_HEADROOM


func _all_unit_ids() -> Array:
	var ids: Array = []
	for def in GameData.all_units():
		ids.append(def.id)
	return ids


func _refresh_shop() -> void:
	var p := player()
	for slot in _shop_buttons.size():
		var button := _shop_buttons[slot]
		var def: UnitDef = p.shop[slot]
		if def == null:
			button.disabled = true
			button.show_empty(Style.CELL, Style.CELL)
			continue

		button.disabled = false

		# Il bordo dice la rarità, la figura dice civiltà e ruolo. Lo sfondo
		# schiarito segnala la civiltà preferita scelta nel menu — è l'unico
		# effetto di quella scelta, che resta un aiuto visivo e non un vantaggio.
		var favourite: bool = def.origin == String(_profile.favourite_origin)
		button.show_unit(
			def, 0, UnitSlot.Badge.COST,
			Style.PANEL.lightened(0.12) if favourite else Style.PANEL,
			Style.rarity_color(def.cost), 2, _unit_tooltip(def)
		)


## Segna l'unità come in attesa del lampeggio: lo riceve nella stessa chiamata
## in cui è nata, prima che _refresh_board/_refresh_bench ne aggiornino la
## casella, quindi arriva qui sempre in tempo.
func _on_unit_upgraded(unit: UnitInstance) -> void:
	_level_up_pending[unit.uid] = true


func _refresh_board() -> void:
	var p := player()
	for cell in _cell_buttons:
		_style_unit_button(_cell_buttons[cell], p.unit_at_cell(cell), cell.y == 0)


func _refresh_bench() -> void:
	var p := player()
	var by_slot := {}
	for unit in p.bench_units():
		by_slot[unit.bench_slot] = unit

	for slot in _bench_buttons.size():
		_style_unit_button(_bench_buttons[slot], by_slot.get(slot))


## Aggiorna una casella che rappresenta una posizione: vuota o con un'unità.
func _style_unit_button(button: UnitSlot, unit: UnitInstance, front_line: bool = false) -> void:
	if unit == null:
		var empty_fill := Style.FRONT_LINE if front_line else Style.CELL
		button.show_empty(empty_fill, Style.CELL.lightened(0.06))
		return

	var border := Style.SELECTED if unit == selected else Style.rarity_color(unit.def.cost)
	button.show_unit(
		unit.def, unit.star, UnitSlot.Badge.STARS,
		Style.PANEL, border, 3 if unit == selected else 2, _unit_tooltip(unit.def)
	)
	if _level_up_pending.erase(unit.uid):
		button.play_level_up_flash()


func _unit_tooltip(def: UnitDef) -> String:
	var traits: Array[String] = []
	for trait_id in def.traits():
		traits.append(GameData.trait_name(trait_id))

	var stats := def.base_stats
	return "%s (%d oro)\n%s\n\nSalute %d   Danno %d   Gittata %d\nVelocità d'attacco %.2f\nArmatura %d   Res. magica %d\n\n%s: %s" % [
		def.display_name, def.cost, ", ".join(traits),
		int(stats.get("hp", 0)), int(stats.get("attack_damage", 0)), int(stats.get("range", 1)),
		float(stats.get("attack_speed", 0.0)),
		int(stats.get("armor", 0)), int(stats.get("magic_resist", 0)),
		def.ability.get("name", "—"), def.ability.get("description", ""),
	]


func _log(text: String) -> void:
	_log_label.append_text(text + "\n")
