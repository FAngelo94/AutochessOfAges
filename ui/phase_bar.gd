class_name PhaseBar
extends Control

## Barra del tempo di una fase: si riempie da sinistra a destra nell'arco dei
## secondi che la fase dura.
##
## È lo stesso oggetto in preparazione e in battaglia — è questo il punto: le
## due fasi durano lo stesso tempo e il giocatore impara a leggere una sola
## barra invece di due indicatori diversi. Chi la usa le passa il tempo
## trascorso, la barra non tiene un orologio proprio: in battaglia il tempo
## viene dalla riproduzione del log, in preparazione dal conto alla rovescia
## della sessione, e nessuno dei due è un orologio che la barra possa indovinare.
##
## L'ultimo tratto — da `berserk_at` in poi — è colorato di rosso: è la finestra
## in cui la simulazione va a velocità tripla, e si vede arrivare prima che
## succeda.

const HEIGHT := 24.0

const TRACK := Color(0.10, 0.11, 0.17)
const EDGE := Color(0.30, 0.31, 0.42)
const FILL := Color(0.98, 0.78, 0.28)
const FILL_BERSERK := Color(0.95, 0.33, 0.26)
const ZONE_BERSERK := Color(0.42, 0.13, 0.13)
## Sotto questa soglia il numero dei secondi diventa rosso: gli ultimi istanti
## per cambiare schieramento si devono notare senza guardare l'orologio.
const URGENT_SECONDS := 5.0

## Durata totale della fase in secondi. 0 = barra vuota, nessuna divisione per zero.
var total: float = 0.0
## Secondi trascorsi. Chi usa la barra lo aggiorna; viene sempre mostrato
## limitato a [0, total], così un conto alla rovescia che sfora non la rompe.
var elapsed: float = 0.0
## Inizio della finestra rossa, in secondi. < 0 = nessuna finestra (preparazione).
var berserk_at: float = -1.0
## Scrive i secondi mancanti sopra la barra. Acceso in preparazione, dove la
## barra è l'unico orologio; spento in battaglia, che ha già il suo contatore
## nell'angolo del campo.
var show_remaining: bool = false

var _font: Font


func _init() -> void:
	custom_minimum_size = Vector2(0, HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_font = ThemeDB.fallback_font


func configure(total_seconds: float, berserk_seconds: float = -1.0) -> void:
	total = maxf(0.0, total_seconds)
	berserk_at = berserk_seconds
	elapsed = 0.0
	queue_redraw()


func set_elapsed(seconds: float) -> void:
	var clamped: float = clampf(seconds, 0.0, total)
	if is_equal_approx(clamped, elapsed):
		return
	elapsed = clamped
	queue_redraw()


## Frazione riempita, 0..1. Pubblica perché i test headless leggono questa
## invece di ispezionare il disegno.
func ratio() -> float:
	if total <= 0.0:
		return 0.0
	return clampf(elapsed / total, 0.0, 1.0)


func _draw() -> void:
	var track := Rect2(Vector2.ZERO, Vector2(size.x, HEIGHT))
	draw_rect(track, TRACK, true)

	# La zona del berserk resta visibile anche prima di essere raggiunta: è un
	# avviso, non un effetto che compare a cose fatte.
	if berserk_at >= 0.0 and total > 0.0 and berserk_at < total:
		var from := size.x * (berserk_at / total)
		draw_rect(Rect2(Vector2(from, 0.0), Vector2(size.x - from, HEIGHT)), ZONE_BERSERK, true)

	var in_berserk := berserk_at >= 0.0 and elapsed >= berserk_at
	var filled := size.x * ratio()
	if filled > 0.0:
		draw_rect(Rect2(Vector2.ZERO, Vector2(filled, HEIGHT)),
			FILL_BERSERK if in_berserk else FILL, true)

	draw_rect(track, EDGE, false, 2.0)

	if not show_remaining or _font == null or total <= 0.0:
		return
	var left := maxf(0.0, total - elapsed)
	var text := "%d s" % int(ceil(left))
	var font_size := 16
	var width := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var at := Vector2((size.x - width) * 0.5, HEIGHT * 0.5 + font_size * 0.36)
	# Contorno scuro: il numero sta al centro della barra e attraversa il
	# confine fra parte piena e parte vuota, quindi nessun colore unico
	# resterebbe leggibile su entrambi i fondi.
	for offset in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		draw_string(_font, at + offset, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			Color(0.04, 0.04, 0.07, 0.9))
	var urgent := left <= URGENT_SECONDS or in_berserk
	draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
		Color(1.0, 0.72, 0.66) if urgent else Color(0.94, 0.94, 0.98))
