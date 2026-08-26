class_name Hex
extends RefCounted

## Geometria della griglia esagonale del campo di battaglia.
##
## Le celle restano `Vector2i(colonna, riga)` come in una griglia quadrata: è
## il sistema "offset per righe" (odd-r), in cui le righe dispari sono spostate
## di mezza cella verso destra. Le coordinate non cambiano — schieramenti,
## salvataggi e log di battaglia restano identici — cambia il vicinato: sei
## vicini invece di otto, e nessuna diagonale che costi quanto un passo dritto.
##
## I conti veri si fanno in coordinate cubiche, dove la distanza esagonale è
## una formula sola e non dipende dalla parità della riga. Convertire avanti e
## indietro costa poco e toglie di mezzo un'intera classe di errori: le
## formule in coordinate offset vanno scritte due volte, una per le righe pari
## e una per le dispari, ed è lì che si annidano i bug difficili da vedere.

## Direzioni cubiche dei sei vicini, in ordine fisso. L'ordine decide quale
## percorso, fra più percorsi di pari lunghezza, sceglie la ricerca in ampiezza
## del risolutore: cambiarlo cambierebbe l'esito di battaglie già registrate,
## quindi non si tocca.
const CUBE_DIRECTIONS: Array[Vector3i] = [
	Vector3i(0, -1, 1), Vector3i(1, -1, 0), Vector3i(1, 0, -1),
	Vector3i(0, 1, -1), Vector3i(-1, 1, 0), Vector3i(-1, 0, 1),
]

## Rapporto fra il passo verticale (da riga a riga) e quello orizzontale (da
## colonna a colonna), per esagoni con la punta in alto: 1.5·R contro √3·R.
## Serve al disegno, non alla simulazione — per la simulazione ogni passo vale
## uno, ed è tutto il senso di una griglia esagonale.
const ROW_STEP_RATIO := 0.86602540378


## Da coordinate offset a cubiche. La somma delle tre componenti è sempre zero:
## è l'invariante che rende la distanza una sottrazione.
static func to_cube(cell: Vector2i) -> Vector3i:
	@warning_ignore("integer_division")
	var x: int = cell.x - (cell.y - (cell.y & 1)) / 2
	var z := cell.y
	return Vector3i(x, -x - z, z)


static func from_cube(cube: Vector3i) -> Vector2i:
	@warning_ignore("integer_division")
	var column: int = cube.x + (cube.z - (cube.z & 1)) / 2
	return Vector2i(column, cube.z)


## Distanza in passi fra due celle.
static func distance(a: Vector2i, b: Vector2i) -> int:
	var ca := to_cube(a)
	var cb := to_cube(b)
	@warning_ignore("integer_division")
	var steps: int = (absi(ca.x - cb.x) + absi(ca.y - cb.y) + absi(ca.z - cb.z)) / 2
	return steps


## Le sei celle adiacenti. Non controlla i bordi: i limiti dell'arena li
## conosce il risolutore, non la geometria.
static func neighbours(cell: Vector2i) -> Array[Vector2i]:
	var cube := to_cube(cell)
	var result: Array[Vector2i] = []
	for direction in CUBE_DIRECTIONS:
		result.append(from_cube(cube + direction))
	return result


## Posizione di una cella sul piano, in unità di cella (1.0 = passo fra due
## colonne). Accetta righe frazionarie, perché durante uno spostamento
## un'unità sta fra due righe, e interpola fra le due posizioni intere: lo
## scarto di mezza cella dipende dalla parità della riga, quindi non è una
## funzione continua e non si può calcolare direttamente su una riga a metà.
static func to_plane(cell: Vector2) -> Vector2:
	var low := floori(cell.y)
	var t := cell.y - float(low)
	var start := _row_plane(cell.x, low)
	if is_zero_approx(t):
		return start
	return start.lerp(_row_plane(cell.x, low + 1), t)


static func _row_plane(column: float, row: int) -> Vector2:
	var shift := 0.5 if absi(row) % 2 == 1 else 0.0
	return Vector2(column + shift, float(row) * ROW_STEP_RATIO)
