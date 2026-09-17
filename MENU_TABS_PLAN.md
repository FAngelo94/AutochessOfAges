# MENU_TABS_PLAN — home a schede con barra di navigazione in basso

Stato: **implementato** (2026-09-17). Differenze dal piano: icone delle schede come Label interne (emoji più grandi), filo d'oro animato sopra la scheda attiva, test di swipe su Negozio↔Collezione per non marcare la guida come vista. Scritto per essere eseguito senza il contesto della conversazione.

## Obiettivo

Oggi `ui/menu.gd` ammucchia sotto BATTAGLIA due righe di pulsanti (Guida, Collezione, Negozio /
🏆, Cronologia, ⚙️ — `ui/menu.gd:788-849`) che aprono pannelli a tutto schermo sovrapposti
(`ui/menu.gd:191-207`). Si sostituisce con:

- una **barra di navigazione fissa in basso**, sempre visibile, con 5 schede nell'ordine:
  **Negozio · Collezione · Battaglia · Guida · Cronologia**;
- ogni scheda è una **pagina**; cambiare scheda fa **scorrere** le pagine orizzontalmente
  (verso sinistra se la destinazione sta a destra, e viceversa);
- anche lo **swipe** orizzontale col dito cambia pagina (alla scheda adiacente);
- la scheda **Battaglia** è la home (pagina iniziale) e contiene il vero pulsante BATTAGLIA che
  avvia la partita, con eroe 🛡️ e modalità 🖥️/👥 ai lati come oggi.

### Decisioni già prese — non rimetterle in discussione

1. Battaglia è la scheda centrale (indice 2) ed è sempre la pagina iniziale all'apertura di
   `menu.tscn`, anche rientrando da una partita.
2. **Classifica** non ha una scheda propria: vive dentro la pagina Cronologia, con un selettore a
   due segmenti in cima `📜 Partite | 🏆 Classifica` (default: Partite).
3. **Impostazioni** ⚙️ non ha una scheda: è un pulsante-icona nell'angolo in alto a destra della
   sola pagina Battaglia, e apre `SettingsPanel` come modale sopra tutto (barra compresa), come oggi.
4. I pannelli esistenti (`StorePanel`, `CollectionPanel`, `GuidePanel`, `HistoryPanel`,
   `LeaderboardPanel`) **si riusano** in "modalità incorporata": niente riscrittura del loro
   contenuto.
5. Modali eroe/dettaglio eroe/modalità (`_build_small_modal`) restano come sono e coprono anche la
   barra.
6. Resta una sola scena: il pager è dentro `ui/menu.tscn`, nessuna nuova scena.

## Invarianti da non violare

- `core/` non viene toccato.
- `menu.gd` resta la sola scena di partenza verso `main.tscn`/`lobby.tscn`
  (`_on_play_pressed`, `_start_pvp` invariati, `ui/menu.gd:908-938`).
- Nessun bersaglio tattile sotto `Style.TOUCH_MIN` (96).
- Nessun numero di bilanciamento o testo hardcoded: ogni stringa nuova va in
  `translations/ui.csv` (colonne `keys,it,en`).
- Il pulsante Guida resta **dorato finché la guida non è mai stata aperta**
  (`ui/menu.gd:852-860`): ora la doratura va sulla **scheda Guida** della barra.
- I test headless non devono dipendere dal rendering: tutto il pager deve funzionare anche con
  `--headless` (dimensioni viewport 720×1280 di default).
- Il modello 3D dell'eroe (`_hero_viewport`, `UPDATE_ALWAYS`) **non deve renderizzare** quando la
  pagina Battaglia non è quella attiva.

## Layout finale

```
┌──────────────────────────────┐
│                              │
│   PAGINA ATTIVA              │  ← _pages_clip (clip_contents), altezza = schermo − barra
│   (le altre 4 affiancate     │     _pages_strip: HBox largo 5×W, si sposta in x
│    fuori dallo schermo)      │
│                              │
├──────┬──────┬──────┬──────┬──┤
│ 🛒   │ 🎴   │ ⚔️   │ 📖   │📜│  ← _tab_bar, altezza TAB_BAR_HEIGHT + inset area sicura
│Negoz.│Coll. │BATT. │Guida │Cr│     scheda centrale rialzata di TAB_CENTER_RAISE
└──────┴──────┴──────┴──────┴──┘
```

Pagina Battaglia: identica all'attuale home **meno** `_nav_bar()`: fondale cielo + `CastleBackdrop`,
banner, spaziatore elastico, vetrina eroe, rank, `_battle_row()`; più ⚙️ in alto a destra.

---

## Milestone 1 — Modalità incorporata nei pannelli

**File:** `ui/store_panel.gd`, `ui/collection_panel.gd`, `ui/guide_panel.gd`,
`ui/history_panel.gd`, `ui/leaderboard_panel.gd`.

**Task** (identici per ognuno dei 5 pannelli):

1. Aggiungere, subito dopo `signal closed`:
   ```gdscript
   ## Vero quando il pannello è una pagina della home a schede (ui/menu.gd):
   ## niente pulsante Chiudi — si esce cambiando scheda — e la visibilità la
   ## decide il contenitore, non open().
   var embedded := false
   ```
2. In `_ready()`: se `embedded`, **non** impostare `visible = false` (resta visibile dentro la
   sua pagina). Lasciare tutto il resto.
3. In `_build()`: creare il pulsante Chiudi solo `if not embedded:` (es.
   `ui/collection_panel.gd:126-134`, `ui/guide_panel.gd:65-73`, `ui/store_panel.gd:111-119`).
4. In `open()`: la riga `visible = true` resta (innocua in modalità incorporata).
5. `margin_bottom` in modalità incorporata: portarlo a `8` (la barra sotto dà già aria).

`embedded` va impostato **prima** di `add_child` (che fa scattare `_ready`).

**Criteri di accettazione**
- `menu_smoke` e `ui_smoke` passano senza altre modifiche (nessuno oggi imposta `embedded`).
- Un pannello con `embedded = true` non ha nessun `Button` con testo `tr("UI_CLOSE")` tra i
  discendenti diretti della sua colonna.

## Milestone 2 — Pager e barra in `ui/menu.gd`

**File:** `ui/menu.gd`, `translations/ui.csv`.

### Costanti e variabili (vincolanti)

```gdscript
const TAB_STORE := 0
const TAB_COLLECTION := 1
const TAB_BATTLE := 2
const TAB_GUIDE := 3
const TAB_HISTORY := 4
const TAB_COUNT := 5

const TAB_BAR_HEIGHT := 112          # >= Style.TOUCH_MIN + etichetta
const TAB_CENTER_RAISE := 18         # la scheda Battaglia sporge sopra la barra
const PAGE_SLIDE_SECONDS := 0.28
## Spostamento orizzontale minimo perché un trascinamento conti come swipe,
## e rapporto minimo orizzontale/verticale: sotto, è uno scroll verticale.
const SWIPE_MIN_PX := 90.0
const SWIPE_AXIS_RATIO := 1.6

var _current_tab := TAB_BATTLE
var _pages_clip: Control
var _pages_strip: Control            # Control semplice, figli posizionati a mano
var _pages: Array[Control] = []      # indice = TAB_*
var _tab_buttons: Array[Button] = []
var _page_tween: Tween
var _swipe_start := Vector2.ZERO
var _swipe_tracking := false
## Rettangoli in cui un trascinamento orizzontale ha già un significato
## (ruotare l'eroe, scorrere i filtri della collezione): lì non si cambia pagina.
var _swipe_blockers: Array[Control] = []

var _history_toggle_matches: Button
var _history_toggle_leaderboard: Button
```

`_guide_button` sparisce: al suo posto `_tab_buttons[TAB_GUIDE]`.

### Funzioni (firme vincolanti)

```gdscript
func _build() -> void
func _build_battle_page() -> Control
func _build_panel_page(panel: Panel) -> Control
func _build_history_page() -> Control
func _build_tab_bar() -> Control
func _tab_button(index: int, icon: String, label_key: String) -> Button
func _layout_pages() -> void
func select_tab(index: int, animate: bool = true) -> void
func _on_tab_activated(index: int) -> void
func _show_history_section(leaderboard: bool) -> void
func _update_tab_buttons() -> void
func _input(event: InputEvent) -> void
func _notification(what: int) -> void
```

### Task

1. **`_build()`** riscritto:
   - `_pages_clip`: `Control`, anchors full rect, `offset_bottom = -(TAB_BAR_HEIGHT + bottom_inset)`,
     `clip_contents = true`. `bottom_inset` = area sicura inferiore convertita in unità viewport,
     stessa conversione di `StorePanel._safe_top_margin()` (`ui/store_panel.gd:133-152`) ma su
     `screen.y - (safe.position.y + safe.size.y)`; 0 in headless. Estrarre la conversione in
     `Style` come `static func safe_insets() -> Vector2` (x = alto, y = basso) e usarla anche da
     `StorePanel` per non duplicarla.
   - `_pages_strip`: `Control` figlio di `_pages_clip`.
   - Creare le 5 pagine **nell'ordine TAB_*** e aggiungerle a `_pages_strip` e a `_pages`:
     - `TAB_STORE` → `_build_panel_page(_store_panel)` con `_store_panel = StorePanel.new()` +
       `embedded = true`
     - `TAB_COLLECTION` → idem con `CollectionPanel`
     - `TAB_BATTLE` → `_build_battle_page()`
     - `TAB_GUIDE` → idem con `GuidePanel`
     - `TAB_HISTORY` → `_build_history_page()`
   - `add_child(_build_tab_bar())`.
   - **Dopo** la barra: `_settings_panel = SettingsPanel.new(); add_child(...)` (non incorporato),
     poi `_build_mode_panel()`, `_build_hero_panel()`, `_build_hero_detail_panel()` e i relativi
     `_update_*` come oggi. L'ordine conta: ciò che è aggiunto dopo sta sopra.
   - `resized.connect(_layout_pages)`; chiamare `_layout_pages()` e `select_tab(TAB_BATTLE, false)`.
2. **`_build_panel_page(panel)`**: `Control` contenitore; `add_child(panel)` (il pannello si
   ancora full rect da solo nel suo `_ready`). Ritorna il contenitore.
3. **`_build_battle_page()`**: sposta qui il corpo attuale di `_build()` righe
   `ui/menu.gd:150-189` (backdrop, `CastleBackdrop`, margin, scroll, colonna, banner, spaziatore,
   eroe, rank, `_battle_row()`), aggiungendo tutto al contenitore pagina invece che a `self`.
   **Rimuovere** `column.add_child(_nav_bar())`. Aggiungere il pulsante ⚙️: `Button`
   `Style.TOUCH_MIN`×`Style.TOUCH_MIN`, plate `PLATE/PLATE_DARK`, ancorato
   `PRESET_TOP_RIGHT` con offset 12 px dal bordo destro e `12 + safe_insets().x` dall'alto,
   `pressed → _settings_panel.open()`. Dopo aver creato la vetrina eroe, aggiungere il suo
   `SubViewportContainer` a `_swipe_blockers`.
4. **`_build_history_page()`**: `VBoxContainer` full rect. In cima un `HBoxContainer` con
   margine superiore `safe_insets().x + 12` e laterali 20, contenente i due pulsanti
   `_history_toggle_matches` (`"📜 " + tr("MENU_HISTORY")`) e
   `_history_toggle_leaderboard` (`"🏆 " + tr("MENU_LEADERBOARD")`), `SIZE_EXPAND_FILL`, altezza
   `Style.TOUCH_MIN`. Sotto, un `Control` `SIZE_EXPAND_FILL` che contiene **entrambi**
   `_history_panel` e `_leaderboard_panel` (incorporati). Nei due pannelli, in modalità
   incorporata, `margin_top` va a `12` (il selettore sopra ha già gestito l'area sicura) —
   aggiungere questa condizione nella Milestone 1 per questi due soli pannelli.
5. **`_show_history_section(leaderboard)`**: `_history_panel.visible = not leaderboard`,
   `_leaderboard_panel.visible = leaderboard`, chiama `open()` su quello visibile, colora il
   segmento attivo con `Style.apply_plate(b, Style.GOLD, Style.GOLD_DEEP, 18, 6)` + font `INK`,
   l'altro con `PLATE/PLATE_DARK` + font `TEXT_DIM` (stesso schema di `_update_mode_button`,
   `ui/menu.gd:971-975`).
6. **`_build_tab_bar()`**: `PanelContainer` ancorato `PRESET_BOTTOM_WIDE`, altezza
   `TAB_BAR_HEIGHT + bottom_inset`, stylebox `Style.box(Style.STONE_DARK, Style.GOLD_DEEP, 0, 0)`
   con bordo superiore dorato di 2 px. Dentro, `HBoxContainer` con separazione 4 e le 5 schede da
   `_tab_button`, tutte `SIZE_EXPAND_FILL`:
   | indice | icona | chiave |
   |---|---|---|
   | TAB_STORE | 🛒 | `MENU_STORE` |
   | TAB_COLLECTION | 🎴 | `MENU_COLLECTION` |
   | TAB_BATTLE | ⚔️ | `MENU_TAB_BATTLE` (nuova) |
   | TAB_GUIDE | 📖 | `MENU_GUIDE` |
   | TAB_HISTORY | 📜 | `MENU_HISTORY` |
7. **`_tab_button(index, icon, label_key)`**: `Button` con testo `icon + "\n" + tr(label_key)`,
   `font_size` 16 (icona e testo sulla stessa label: niente nodi figli che rubino il click),
   `custom_minimum_size.y = TAB_BAR_HEIGHT`, `clip_text = true`,
   `pressed → select_tab(index)`. La scheda `TAB_BATTLE` ha `custom_minimum_size.y =
   TAB_BAR_HEIGHT + TAB_CENTER_RAISE`, `size_flags_vertical = SIZE_SHRINK_END` e font 18: sporge
   sopra la barra (al `PanelContainer` mettere `clip_contents = false`).
8. **`_layout_pages()`**: `W = _pages_clip.size.x`, `H = _pages_clip.size.y`; per ogni `i`:
   `_pages[i].position = Vector2(i * W, 0)`, `_pages[i].size = Vector2(W, H)`;
   `_pages_strip.size = Vector2(TAB_COUNT * W, H)`; `_pages_strip.position.x = -_current_tab * W`
   (senza animazione — un resize non deve far scorrere nulla).
9. **`select_tab(index, animate)`**:
   - `index = clampi(index, 0, TAB_COUNT - 1)`; se uguale a `_current_tab` e `animate`, return.
   - `_current_tab = index`; `_update_tab_buttons()`; `_on_tab_activated(index)`.
   - Target `x = -index * _pages_clip.size.x`. Se `animate`: uccidere `_page_tween` se valido,
     `create_tween()`, `tween_property(_pages_strip, "position:x", x, PAGE_SLIDE_SECONDS)` con
     `TRANS_CUBIC`/`EASE_OUT`. Altrimenti assegnare direttamente.
   - La direzione (destra→sinistra o viceversa) viene gratis dal segno della differenza: non
     serve altro codice.
10. **`_on_tab_activated(index)`**:
    - `_hero_viewport.render_target_update_mode = UPDATE_ALWAYS if index == TAB_BATTLE else
      UPDATE_DISABLED`. Non toccare `_hero_auto_rotating`: si ferma solo il rendering.
    - `TAB_STORE` → `_store_panel.open()`; `TAB_COLLECTION` → `_collection_panel.open()`;
      `TAB_GUIDE` → `_guide_panel.open()` poi `_update_tab_buttons()` (doratura);
      `TAB_HISTORY` → `_show_history_section(_leaderboard_panel.visible)` (ricorda il segmento).
    - Chiudere eventuali schede di dettaglio rimaste aperte nella collezione:
      `_collection_panel._detail_sheet.visible = false` quando si **lascia** TAB_COLLECTION.
11. **`_update_tab_buttons()`**: scheda attiva → `Style.apply_plate(b, Style.GOLD, Style.GOLD_DEEP,
    16, 6)` + `font_color` `INK`; inattive → `Style.PLATE/PLATE_DARK` + `TEXT_DIM`. Eccezione:
    la scheda Guida **inattiva** e `not _profile.has_seen_tip("guide_opened")` → plate
    `BLUE/BLUE_DEEP` con testo `GOLD` e un "•" davanti al testo (richiamo senza sembrare attiva).
12. **`_input(event)`** — swipe:
    - Ignorare tutto se è visibile una modale (`_hero_panel`, `_hero_detail_panel`,
      `_mode_panel`, `_settings_panel`) o la scheda dettaglio collezione
      (`_collection_panel._detail_sheet.visible`).
    - `InputEventScreenTouch`/`InputEventMouseButton` sinistro premuto: se la posizione è dentro
      `_pages_clip.get_global_rect()` e fuori da ogni `b.get_global_rect()` di `_swipe_blockers`
      (solo quelli `is_visible_in_tree()`), `_swipe_tracking = true`, `_swipe_start = pos`.
    - Rilascio con `_swipe_tracking`: `d = pos - _swipe_start`; se `absf(d.x) >= SWIPE_MIN_PX` e
      `absf(d.x) >= absf(d.y) * SWIPE_AXIS_RATIO` → `select_tab(_current_tab + (1 if d.x < 0
      else -1))`. In ogni caso `_swipe_tracking = false`.
    - **Non** chiamare `set_input_as_handled()`: il tocco deve arrivare comunque ai pulsanti e agli
      scroll (un pulsante sotto un piccolo trascinamento resta premibile).
    - Aggiungere a `_swipe_blockers` anche lo `ScrollContainer` dei filtri della collezione
      (`ui/collection_panel.gd:99-102`): esporlo come `var filter_scroll: ScrollContainer`.
13. **`_notification(what)`**: su `NOTIFICATION_WM_GO_BACK_REQUEST` (tasto indietro Android), se
    una modale è aperta chiuderla; altrimenti se `_current_tab != TAB_BATTLE` →
    `select_tab(TAB_BATTLE)`. Solo su Battaglia il comportamento resta quello di sistema.
14. **Rimuovere** `_nav_bar()`, `_guide_button`, `_update_guide_button()`, `_section()` e
    `_spacer()` se restano inutilizzati. `_on_guide_pressed`, `_on_collection_pressed`,
    `_on_store_pressed` **restano** ma diventano `select_tab(TAB_GUIDE/COLLECTION/STORE)` (li usano
    i test). Aggiungere `func _on_history_pressed() -> void: select_tab(TAB_HISTORY);
    _show_history_section(false)` e `func _on_leaderboard_pressed() -> void:
    select_tab(TAB_HISTORY); _show_history_section(true)`.
15. **`_apply_layout()`** (`ui/menu.gd:223-230`) resta, ma misura lo scroll della pagina
    Battaglia; va richiamato anche da `_layout_pages()` dopo il primo layout (la pagina cambia
    altezza perché ora c'è la barra).
16. **`translations/ui.csv`**: aggiungere `MENU_TAB_BATTLE,Battaglia,Battle`. Controllare che le
    etichette entrino in ~136 px a font 16: "Collezione"/"Collection" è la più lunga; se in
    screenshot viene tagliata, aggiungere chiavi brevi `MENU_TAB_COLLECTION,Unità,Units` ecc.
    invece di rimpicciolire il font.

**Criteri di accettazione**
- All'avvio del menu `_current_tab == TAB_BATTLE` e `_pages_strip.position.x == -2 * W`.
- `select_tab(TAB_STORE, false)` → `_pages_strip.position.x == 0` e
  `_hero_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED`.
- Nessuna pagina esce dalla larghezza del viewport quando attiva (niente scroll orizzontale).
- Premere BATTAGLIA dalla pagina Battaglia porta a `main.tscn` come prima.

## Milestone 3 — Test

**File:** `tests/menu_smoke.gd`, `tests/screenshot.gd`.

1. `menu_smoke.gd`: le chiamate `_on_collection_pressed()`, `_on_guide_pressed()`,
   `_on_store_pressed()` restano valide. Sostituire:
   - `collection.visible = false`, `guide.visible = false`, `_menu._store_panel.visible = false`,
     `history.visible = false`, `leaderboard.visible = false` → rimuoverle (non servono più;
     impostare `visible = false` su un pannello incorporato lo farebbe sparire dalla pagina).
   - `history.open()` → `_menu._on_history_pressed()`; `leaderboard.open()` →
     `_menu._on_leaderboard_pressed()`.
   - `check(collection.visible, ...)` ecc. → `check(_menu._current_tab == _menu.TAB_COLLECTION, ...)`
     (e analoghi).
2. Nuovi check in `menu_smoke.gd`, subito dopo i controlli di costruzione (`~riga 76`):
   - `"il menu parte dalla scheda battaglia"`: `_menu._current_tab == _menu.TAB_BATTLE`.
   - `"ci sono cinque schede"`: `_menu._tab_buttons.size() == 5`.
   - `"i pannelli in home non hanno il pulsante chiudi"`: nessun `Button` con testo
     `tr("UI_CLOSE")` tra i discendenti di `_menu._collection_panel` **esclusa** la sua
     `_detail_sheet` (quella ha un proprio chiudi legittimo — verificarlo prima di scrivere il check).
   - `"uno swipe verso sinistra passa alla scheda a destra"`: da `TAB_BATTLE`, iniettare con
     `_menu._input()` un `InputEventMouseButton` premuto a `(600, 600)` e rilasciato a `(300, 610)`
     → `_current_tab == TAB_GUIDE`. Poi l'inverso → torna a `TAB_BATTLE`.
   - `"uno scroll verticale non cambia scheda"`: premuto `(360, 900)`, rilasciato `(300, 400)` →
     scheda invariata.
   - `"dalla prima scheda non si va oltre"`: `select_tab(TAB_STORE, false)` + swipe verso destra →
     resta `TAB_STORE`.
   - `"la cronologia ricorda il segmento classifica"`: `_on_leaderboard_pressed()`, poi
     `select_tab(TAB_BATTLE, false)`, poi `select_tab(TAB_HISTORY, false)` →
     `_menu._leaderboard_panel.visible`.
3. `screenshot.gd` (`tests/screenshot.gd:50-63`): sostituire `_guide_panel.visible = false` con
   `_menu.select_tab(_menu.TAB_BATTLE, false)`, usare `select_tab(..., false)` per guida e
   collezione (senza animazione, lo scatto è al frame dopo), e aggiungere scatti `negozio.png` e
   `cronologia.png`.

**Criteri di accettazione**
- `menu_smoke`, `ui_smoke --seed=4242`, `run_tests`, `auth_smoke` passano, a parte i 3 fallimenti
  noti pre-esistenti elencati in `CLAUDE.md`.
- `screenshot.gd` (non headless) produce `menu.png` con la barra visibile in basso, BATTAGLIA
  sopra la barra senza sovrapposizione, ⚙️ in alto a destra dentro lo schermo.

## Milestone 4 — Documentazione

- `CLAUDE.md`: nella tabella, riga `ui/menu.gd` → "start screen: 5-tab home (Store, Collection,
  Battle, Guide, History) with a fixed bottom bar and swipe paging; Battle is the landing tab and
  holds hero/mode selection; Leaderboard lives inside History, Settings is a ⚙️ on the Battle page".
  Nella sezione *Screens* aggiungere che i pannelli hanno `embedded` e che in home non si chiudono.
- Aggiornare i commenti in testa a `ui/menu.gd` (righe 3-12) e in `ui/history_panel.gd:12-14`
  ("una schermata piena che copre il menu" non è più vero in modalità incorporata).

---

## Appendice A — Comandi di verifica

```sh
GODOT="/c/Users/afalc/Downloads/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe"
"$GODOT" --headless --path . --import
"$GODOT" --headless --path . --script res://tests/menu_smoke.gd
"$GODOT" --headless --path . --script res://tests/ui_smoke.gd -- --seed=4242
"$GODOT" --headless --path . --script res://tests/run_tests.gd
"$GODOT" --path . --script res://tests/screenshot.gd -- <cartella_scratch>   # NON headless
```

## Appendice B — Trappole note

- **`embedded` va impostato prima di `add_child`**: `_ready()` costruisce subito il pannello.
- **`clip_contents` sul contenitore delle pagine è obbligatorio**, altrimenti le pagine adiacenti
  si vedono ai lati e ricevono i click.
- **Le pagine fuori schermo ricevono comunque input?** No se clippate e fuori dal rettangolo del
  clip, ma un `SubViewportContainer` con `MOUSE_FILTER_STOP` resta attivo: per questo si ferma il
  rendering dell'eroe e si usano i `_swipe_blockers` solo se `is_visible_in_tree()` e dentro il
  clip.
- **Misurare dopo due frame**: `_apply_layout()` attende già due `process_frame`
  (`ui/menu.gd:224-225`) — lo stesso vale per `_layout_pages()` se chiamato in `_ready()`, perché
  `_pages_clip.size` è 0 finché il layout non è passato. Chiamarlo anche da `resized`.
- **Tween durante uno swipe**: se si fa swipe mentre un tween è in corso, `select_tab` deve
  ucciderlo prima di crearne un altro, o due tween si contendono `position:x`.
- **ScrollContainer e swipe**: gli `ScrollContainer` verticali dei pannelli non consumano il
  trascinamento orizzontale (hanno `horizontal_scroll_mode = DISABLED`), ma lo scroll dei filtri
  della collezione sì — per questo sta in `_swipe_blockers`.
- **Guida già vista nei test**: il check `"la guida non è ancora stata vista"` fallisce già su
  macchine con `user://profile.cfg` sporco (noto, vedi `CLAUDE.md`); non è una regressione.
- **Area sicura**: la barra in basso su telefoni con gesture bar deve includere l'inset inferiore,
  altrimenti le schede finiscono sotto la barra di sistema.
