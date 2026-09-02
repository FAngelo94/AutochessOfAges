class_name UnitModels
extends RefCounted

## Costruisce i modelli 3D delle unità assemblando primitive.
##
## Non ci sono file di mesh su disco: ogni figura è un albero di MeshInstance3D
## generato a runtime. È una scelta deliberata finché l'arte non è definitiva —
## i modelli si versionano come codice, si rileggono a colpo d'occhio e si
## modificano senza aprire un software di modellazione.
##
## Le proporzioni sono pensate per la vista dall'alto: conta la silhouette
## proiettata sul piano, non il dettaglio delle facce. Per questo le armi sono
## sovradimensionate e gli scudi larghi — dall'alto sono l'unica cosa che
## distingue un arciere da un lanciere.
##
## Una cella della scacchiera vale 1.0 unità di mondo; un fante è alto ~0.8.

## Unità nella loro posa base guardano verso +Z. Chi orienta il modello sul
## campo è BattleBoard3D, che conosce il lato di ciascuna squadra.
const FORWARD := Vector3(0, 0, 1)

## Palette per civiltà. `primary` è il colore che identifica l'esercito a colpo
## d'occhio, `metal` e `wood` restano vicini fra le civiltà perché il ferro e il
## legno non cambiano colore a seconda di chi li impugna.
const PALETTES := {
	"roman": {
		"primary": Color(0.68, 0.16, 0.14),
		"secondary": Color(0.82, 0.66, 0.28),
		"metal": Color(0.66, 0.68, 0.74),
		"wood": Color(0.46, 0.32, 0.19),
		"cloth": Color(0.88, 0.85, 0.78),
		"skin": Color(0.80, 0.61, 0.45),
	},
	"gaul": {
		"primary": Color(0.28, 0.48, 0.26),
		"secondary": Color(0.78, 0.60, 0.22),
		"metal": Color(0.55, 0.57, 0.60),
		"wood": Color(0.42, 0.29, 0.17),
		"cloth": Color(0.72, 0.66, 0.50),
		"skin": Color(0.84, 0.66, 0.52),
	},
	"teuton": {
		"primary": Color(0.24, 0.36, 0.64),
		"secondary": Color(0.80, 0.80, 0.84),
		"metal": Color(0.60, 0.63, 0.70),
		"wood": Color(0.38, 0.27, 0.16),
		"cloth": Color(0.66, 0.68, 0.74),
		"skin": Color(0.85, 0.69, 0.56),
	},
}

## Archetipi noti, in ordine di priorità: un'unità con più classi prende il
## modello della prima che compare qui. La cavalleria vince sull'assedio perché
## il carro falcato si riconosce dal cavallo, non dal cassone.
const ARCHETYPE_PRIORITY := ["cavalry", "siege", "archer", "druid", "berserker", "legionary"]

## Modelli d'artista, se forniti: un file res://models/<unit_id>.glb ha sempre
## la precedenza sulla figura procedurale per quello stesso id. Un'unità senza
## il suo .glb ricade normalmente sulla figura dedicata o sull'archetipo — la
## presenza di alcuni modelli reali non deve rompere quelle senza.
const MODELS_DIR := "res://models/"

## Ritocco fine della taglia dei modelli d'artista, applicato sopra la
## normalizzazione all'altezza dell'archetipo. Un .glb largo e basso (il carro
## falcato) può sembrare troppo ingombrante nella cella pur essendo "alto
## giusto": qui lo si rimpicciolisce un filo. 1.0 (assente) = nessun ritocco.
const CUSTOM_MODEL_SCALE := {
	"chariot": 0.85,
}

## Materiali riusati fra tutte le istanze: un esercito è fatto di poche tinte
## ripetute, e allocarne una copia per ogni cubo sprecherebbe draw call.
static var _materials: Dictionary = {}


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

## Modello completo di un'unità. `unit_id` sceglie la figura specifica se
## esiste, altrimenti si ricade sull'archetipo tinto con la palette della
## civiltà. La radice guarda verso +Z e poggia sull'origine (y = 0).
static func build(unit_id: String, origin: String) -> Node3D:
	var palette: Dictionary = PALETTES.get(origin, PALETTES["roman"])
	var root := Node3D.new()
	root.name = "Model_%s" % unit_id

	var custom := _load_custom_model(unit_id)
	if custom != null:
		var tuned: float = height_of(unit_id) * float(CUSTOM_MODEL_SCALE.get(unit_id, 1.0))
		_normalize_custom_model(custom, tuned)
		_recolor_custom_model(custom, palette)
		root.add_child(custom)
		return root

	match unit_id:
		"legionarius": _build_legionarius(root, palette)
		"velites": _build_velites(root, palette)
		"centurio": _build_centurio(root, palette)
		"cataphractus": _build_cataphractus(root, palette)
		"sagittarius": _build_sagittarius(root, palette)
		"ballistarius": _build_ballistarius(root, palette)
		"equites": _build_equites(root, palette)
		"clansman": _build_clansman(root, palette)
		"gaul_hunter": _build_gaul_hunter(root, palette)
		"gaul_druid": _build_gaul_druid(root, palette)
		"chariot": _build_chariot(root, palette)
		"gaul_champion": _build_gaul_champion(root, palette)
		"solduros": _build_solduros(root, palette)
		"gaul_slinger": _build_gaul_slinger(root, palette)
		"teuton_spearman": _build_teuton_spearman(root, palette)
		"teuton_skirmisher": _build_teuton_skirmisher(root, palette)
		"shieldmaiden": _build_shieldmaiden(root, palette)
		"seeress": _build_seeress(root, palette)
		"battering_ram": _build_battering_ram(root, palette)
		"arminius": _build_arminius(root, palette)
		_: _build_archetype(root, palette, archetype_of(unit_id))

	return root


## Istanzia res://models/<unit_id>.glb se il file esiste, altrimenti null: è il
## segnale per build() di ricadere sulla figura procedurale. ResourceLoader
## restituisce false su un percorso assente senza sollevare errori, quindi
## questa funzione è sicura da chiamare per ognuna delle unità, fornito o no.
static func _load_custom_model(unit_id: String) -> Node3D:
	var path := "%s%s.glb" % [MODELS_DIR, unit_id]
	if not ResourceLoader.exists(path):
		return null
	var scene: PackedScene = load(path)
	if scene == null:
		return null
	return scene.instantiate() as Node3D


## Riporta un modello d'artista alla convenzione delle figure procedurali:
## poggia sull'origine (y = 0), centrato su x/z, e alto `target_height` unità di
## mondo (una cella vale 1.0). Un .glb esportato con una scala qualsiasi —
## metri, centimetri, unità di Blender — appare così alla dimensione giusta
## senza doverlo riesportare, e tutti i consumatori (ritratti, collezione,
## scacchiera) lo inquadrano con lo stesso calcolo che usano per le primitive.
static func _normalize_custom_model(node: Node3D, target_height: float) -> void:
	var box := _local_aabb(node, Transform3D.IDENTITY)
	if box.size.y <= 0.0001:
		return
	var factor := target_height / box.size.y
	node.scale = node.scale * factor
	var scaled := box.abs()
	scaled.position *= factor
	scaled.size *= factor
	node.position -= Vector3(
		scaled.position.x + scaled.size.x * 0.5,
		scaled.position.y,
		scaled.position.z + scaled.size.z * 0.5)


## AABB di tutte le mesh sotto `node`, nello spazio del genitore.
static func _local_aabb(node: Node, xform: Transform3D) -> AABB:
	var here := xform
	if node is Node3D:
		here = xform * (node as Node3D).transform
	var acc := AABB()
	var seeded := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		acc = here * (node as MeshInstance3D).mesh.get_aabb()
		seeded = true
	for child in node.get_children():
		var sub := _local_aabb(child, here)
		if sub.size == Vector3.ZERO:
			continue
		acc = acc.merge(sub) if seeded else sub
		seeded = true
	return acc


## Tinte per un .glb esportato senza colori (ogni materiale grigio uniforme):
## si indovina il RUOLO dal nome del materiale — la convenzione è nominarli in
## italiano come nel resto del progetto, con o senza prefisso `MAT_` — e si
## applica la palette della civiltà, così lo stesso modello serve romani, galli
## e teutoni.
##
## Le parole chiave sono confrontate come sottostringhe: elencare sia il
## singolare che il plurale quando differiscono ("asta"/"aste", "punta"/"punte").
## La prima regola che combacia vince, quindi le più specifiche (metallo, cuoio)
## stanno prima delle più generiche (legno). Un materiale che non combacia con
## nessuna regola NON resta bianco: ricade su `cloth` e stampa un avviso, così
## il buco nel vocabolario si vede nei log invece che a schermo.
const _RECOLOR_KEYWORDS: Array = [
	[["occhi", "occhio", "iride", "pupilla", "sopraccigli"], "eyes"],
	[["labbra", "bocca"], "lips"],
	[["pelle", "skin", "incarnato", "viso", "faccia", "mani", "braccia"], "skin"],
	[["capelli", "capello", "hair", "baffi", "barba", "chioma", "crine",
		"biondo", "bionda", "calce", "ramati", "ramato", "rossicci"], "hair"],
	[["pelliccia", "pelo", "fur", "lupo", "orso"], "fur"],
	[["foglie", "foglia", "fogliame", "muschio", "muschi", "vischio", "edera",
		"alloro", "fronde", "ramoscelli"], "foliage"],
	[["avorio", "osso", "ossa", "corna", "corno", "teschio", "cranio", "zanna"], "bone"],
	[["rame", "gemme", "gemma", "bacche", "bacca", "ambra", "smalto"], "copper"],
	[["pietra", "sasso", "roccia", "selce", "ciottolo"], "stone"],
	[["corda", "lino", "spago", "fibra", "canapa", "treccia"], "rope"],
	[["piume", "piuma", "penna", "penne", "cenere", "impennaggio"], "feather"],
	[["bordo", "orlo", "giallo", "gialla", "oro", "dorato", "dorata", "gold",
		"bronzo", "fregi", "torque", "torc"], "secondary"],
	[["metallo", "metal", "ferro", "iron", "acciaio", "steel", "lama", "spada",
		"coltello", "pugnale", "elmo", "elmetto", "punta", "punte", "cuspide",
		"rinforz", "borchie", "falci", "falce", "mozzo", "lorica", "cotta"], "metal"],
	[["cuoio", "cintura", "cinture", "belt", "cinghia", "cinghie", "bisaccia",
		"faretra", "redini", "briglie", "frombola", "fionda", "stivali", "stivale",
		"sandali", "calzari", "guanti", "bretelle", "finimenti"], "leather"],
	[["legno", "wood", "asta", "aste", "lancia", "lance", "scudo", "manico",
		"arco", "bastone", "palo", "picca", "carro", "ruota", "ruote", "timone",
		"mozzo_legno", "freccia", "frecce", "giavellotto"], "wood"],
	[["mantello", "cloak", "cappa", "cappuccio", "cappotto", "manto", "ocra",
		"tabarro"], "cloak"],
	[["bracae", "brache", "braghe", "pantaloni", "breeches", "scacchi",
		"gambali", "gambe", "calzoni"], "breeches"],
	[["verde", "gallico", "gallica", "tunica", "tunic", "casacca", "veste",
		"gonna", "corpo", "busto", "torso", "abito", "primary", "rosso", "rossa",
		"blu"], "primary"],
]


static func _recolor_custom_model(node: Node, palette: Dictionary) -> void:
	for child in node.get_children():
		_recolor_custom_model(child, palette)
	if not (node is MeshInstance3D):
		return
	var mesh_instance := node as MeshInstance3D
	if mesh_instance.mesh == null:
		return
	for surface in mesh_instance.mesh.get_surface_count():
		var source := mesh_instance.get_active_material(surface)
		var mat_name := source.resource_name.to_lower() if source != null else ""
		if mat_name.is_empty():
			mat_name = String(mesh_instance.name).to_lower()
		if _material_already_tinted(source):
			continue
		mesh_instance.set_surface_override_material(surface, _material(_recolor_pick(mat_name, palette)))


## Un .glb che porta già i suoi colori (materiale non grigio uniforme) va
## lasciato com'è: si ridipinge solo l'export "tutto grigio" che si affida ai
## nomi. Soglia larga perché l'export senza colori esce con un grigio ~0.9.
static func _material_already_tinted(mat: Material) -> bool:
	if not (mat is StandardMaterial3D):
		return false
	if (mat as StandardMaterial3D).albedo_texture != null:
		return true
	var c := (mat as StandardMaterial3D).albedo_color
	var grey_ish: bool = abs(c.r - c.g) < 0.03 and abs(c.g - c.b) < 0.03 and c.r > 0.75
	return not grey_ish


static func _recolor_pick(mat_name: String, palette: Dictionary) -> Color:
	for rule in _RECOLOR_KEYWORDS:
		for keyword in rule[0]:
			if mat_name.contains(keyword):
				return _role_color(rule[1], palette)
	push_warning("unit_models: materiale '%s' senza regola di ricolorazione, uso 'cloth'" % mat_name)
	return palette["cloth"].darkened(0.1)


static func _role_color(role: String, palette: Dictionary) -> Color:
	match role:
		"eyes": return Color(0.16, 0.13, 0.11)
		"lips": return palette["skin"].lerp(Color(0.55, 0.24, 0.22), 0.55)
		"hair": return palette["secondary"].lightened(0.30)
		"fur": return palette["cloth"].lerp(palette["wood"], 0.35)
		"foliage": return palette["primary"].lerp(Color(0.16, 0.30, 0.14), 0.5).darkened(0.1)
		"bone": return Color(0.90, 0.85, 0.72)
		"copper": return Color(0.72, 0.45, 0.20)
		"stone": return Color(0.52, 0.52, 0.55)
		"rope": return Color(0.80, 0.72, 0.53)
		"feather": return palette["cloth"].lightened(0.1)
		"leather": return palette["wood"].darkened(0.15)
		"cloak": return palette["primary"].lerp(palette["wood"], 0.45).darkened(0.05)
		"breeches": return palette["primary"].darkened(0.35)
		_: return palette[role]


## Archetipo di un'unità, letto dalle sue classi. Serve sia a scegliere il
## modello di ripiego sia a raggruppare le unità nell'anteprima.
static func archetype_of(unit_id: String) -> String:
	var def := GameData.unit(unit_id)
	if def == null:
		return "legionary"
	for archetype in ARCHETYPE_PRIORITY:
		if def.classes.has(archetype):
			return archetype
	return "legionary"


## Altezza approssimativa del modello, per piazzare barre e testi sopra la
## testa senza doverne calcolare l'AABB reale a ogni fotogramma.
static func height_of(unit_id: String) -> float:
	match archetype_of(unit_id):
		"cavalry": return 1.05
		"siege": return 0.70
		_: return 0.85


## Modello di un eroe. Gli eroi non sono unità: non passano da GameData.unit()
## e non ricadono mai sull'archetipo generico — ogni eroe ha la propria figura,
## per restare riconoscibile nel ritratto grande del menu e negli angoli della
## battaglia. Come per le unità, un file res://models/<hero_id>.glb ha la
## precedenza sulla figura procedurale.
static func build_hero(hero_id: String) -> Node3D:
	var hdef := GameData.hero(hero_id)
	var origin := hdef.origin if hdef != null else "roman"
	var palette: Dictionary = PALETTES.get(origin, PALETTES["roman"])
	var root := Node3D.new()
	root.name = "Hero_%s" % hero_id

	var custom := _load_custom_model(hero_id)
	if custom != null:
		_normalize_custom_model(custom, height_of_hero(hero_id))
		_recolor_custom_model(custom, palette)
		root.add_child(custom)
		return root

	match hero_id:
		"cesare": _build_cesare(root, palette)
		"vercingetorige": _build_vercingetorige(root, palette)
		_: _build_archetype(root, palette, "legionary")

	return root


## Gli eroi sono figure di comando: leggermente più alte degli archetipi
## regolari, per distinguersi a colpo d'occhio nel ritratto e in battaglia.
static func height_of_hero(_hero_id: String) -> float:
	return 0.95


# --------------------------------------------------------------------------
# Figure eroi
# --------------------------------------------------------------------------

## Cesare: il generale romano. Scutum e gladio come il legionario, ma cresta
## trasversale da comandante (come il centurione), corona d'alloro al posto
## dello spallaccio dorato, e un mantello scarlatto da console che nessun'altra
## figura romana porta.
static func _build_cesare(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["secondary"], "scale": 1.18})
	_scutum(root, palette)
	_gladius(root, palette)
	_crest(root, palette, true)
	_cloak(root, palette["primary"].darkened(0.1), 0.36, 0.46)
	# Corona d'alloro: un anello dorato sulla calotta, distinto dallo spallaccio
	# del centurione — qui il segno di comando sta sulla testa, non sulle spalle.
	_add(root, _torus(0.075, 0.10), palette["secondary"],
		_xf(Vector3(0, 0.79, 0), Vector3(90, 0, 0)))


## Vercingetorige: il capo gallico. Stessa base del Solduros (torque, elmo
## cornuto, spada lunga) ma senza vessillo — la sagoma resta pulita per non
## confondersi col portastendardo — e con uno scudo ovale più grande e un
## mantello del colore secondario della tribù, non del primario.
static func _build_vercingetorige(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "scale": 1.2, "shoulders": 0.38})
	_cloak(root, palette["secondary"].darkened(0.15), 0.38, 0.48)
	_torque(root, palette)
	_horns(root, palette["metal"], 0.70)
	_long_sword(root, palette, 0.50)
	var shield := _add(root, _cylinder(0.21, 0.05), palette["secondary"],
		_xf(Vector3(-0.25, 0.42, 0.06), Vector3(90, 0, 0)))
	shield.scale = Vector3(1.0, 1.0, 1.35)
	_add(root, _sphere(0.055), palette["metal"],
		_xf(Vector3(-0.30, 0.42, 0.06), Vector3.ZERO, Vector3(0.6, 1, 1)))


# --------------------------------------------------------------------------
# Figure romane
# --------------------------------------------------------------------------

## Il legionario è il metro di paragone di tutte le altre figure: scudo
## rettangolare a sinistra, gladio corto a destra, elmo con cresta longitudinale.
static func _build_legionarius(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"]})
	_scutum(root, palette)
	_gladius(root, palette)
	_crest(root, palette, false)


## Il velite è la versione leggera del legionario: niente scudo grande né
## corazza, solo una parma piccola e due giavellotti pronti al lancio, con la
## pelle di lupo sull'elmo che ne era il segno distintivo.
static func _build_velites(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "helmet": false, "shoulders": 0.28})
	# Pelle di lupo sul capo, al posto dell'elmo metallico.
	var pelt: Color = palette["wood"]
	pelt = pelt.lightened(0.15)
	_add(root, _sphere(0.09), pelt,
		_xf(Vector3(0, 0.68, -0.01), Vector3.ZERO, Vector3(1.0, 0.85, 1.0)))
	for side in [-1.0, 1.0]:
		_add(root, _cone(0.03, 0.08), pelt,
			_xf(Vector3(side * 0.06, 0.77, -0.01), Vector3(0, 0, side * 16.0)))
	# Parma: scudo piccolo e leggero, molto più contenuto dello scutum.
	_round_shield(root, palette, Vector3(-0.18, 0.38, 0.06), 0.11, palette["secondary"])
	# Due giavellotti leggeri, tenuti pronti al lancio sul fianco destro.
	for i in 2:
		_add(root, _cylinder(0.012, 0.40), palette["wood"],
			_xf(Vector3(0.20 + i * 0.05, 0.42, 0.10 - i * 0.03), Vector3(70, 0, -8)))
		_add(root, _cone(0.022, 0.07), palette["metal"],
			_xf(Vector3(0.20 + i * 0.05, 0.62, 0.30 - i * 0.03), Vector3(70, 0, -8)))


## Il centurione si distingue dal legionario per la cresta trasversale — che
## dall'alto è esattamente il tratto più visibile — e per la vitis al posto del
## gladio.
static func _build_centurio(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "scale": 1.08})
	_scutum(root, palette)
	_crest(root, palette, true)
	# Vitis: il bastone di comando, tenuto alto e obliquo.
	_add(root, _cylinder(0.018, 0.44), palette["wood"],
		_xf(Vector3(0.22, 0.52, 0.06), Vector3(18, 0, -12)))
	# Spallacci dorati: massa in più sulle spalle, visibile dall'alto.
	_add(root, _box(Vector3(0.40, 0.06, 0.24)), palette["secondary"],
		_xf(Vector3(0, 0.56, 0)))


## Il catafratto è la cavalleria più pesante del gioco: armatura anche sul
## cavallo, dove tutte le altre unità a cavallo lasciano il manto scoperto —
## dall'alto è una sagoma piena di metallo, senza il manto colorato a vista.
static func _build_cataphractus(root: Node3D, palette: Dictionary) -> void:
	_horse(root, palette)
	# Corazzatura del cavallo: piastre metalliche sovrapposte al manto, che
	# coprono petto e fianchi dov'è nudo su ogni altro cavallo del gioco.
	_add(root, _box(Vector3(0.29, 0.09, 0.30)), palette["metal"],
		_xf(Vector3(0, 0.52, 0.10)))
	_add(root, _box(Vector3(0.30, 0.07, 0.22)), palette["metal"],
		_xf(Vector3(0, 0.46, -0.14)))
	var rider := Node3D.new()
	rider.position = Vector3(0, 0.52, -0.02)
	root.add_child(rider)
	_humanoid(rider, palette, {"tunic": palette["metal"], "scale": 0.84, "legs": false})
	# Corazza lamellare sul busto del cavaliere, sopra la tunica.
	_add(rider, _box(Vector3(0.34, 0.20, 0.16)), palette["metal"],
		_xf(Vector3(0, 0.41, 0.03)))
	# Contus: la lancia lunga impugnata a due mani, ben oltre la portata
	# dell'hasta dell'equite.
	_add(rider, _cylinder(0.018, 0.86), palette["wood"],
		_xf(Vector3(0.18, 0.36, 0.20), Vector3(80, 0, 0)))
	_add(rider, _cone(0.038, 0.11), palette["metal"],
		_xf(Vector3(0.18, 0.44, 0.61), Vector3(80, 0, 0)))


## L'arciere si legge dall'arco: un arco teso è l'unica curva ampia in tutto
## l'esercito, e dall'alto resta un arco anche schiacciato sul piano.
static func _build_sagittarius(root: Node3D, palette: Dictionary) -> void:
	# Tunica nel colore della civiltà, non in quello d'accento: con l'accento
	# l'arciere diventava una macchia gialla che non si legava al resto
	# dell'esercito.
	_humanoid(root, palette, {"tunic": palette["primary"], "helmet": false})
	_bow(root, palette, Vector3(0.03, 0.46, 0.13))
	# Faretra sulla schiena, con le frecce che spuntano.
	_add(root, _cylinder(0.055, 0.28), palette["wood"],
		_xf(Vector3(-0.14, 0.44, -0.12), Vector3(0, 0, 24)))
	for i in 3:
		_add(root, _cylinder(0.008, 0.16), palette["cloth"],
			_xf(Vector3(-0.17 + i * 0.03, 0.62, -0.13), Vector3(0, 0, 24)))


## La balista dei balistari è una macchina: larga, bassa, senza gambe. La
## sagoma a T con le braccia aperte la distingue da qualunque fante anche a
## occhio nudo dall'alto.
static func _build_ballistarius(root: Node3D, palette: Dictionary) -> void:
	# Telaio e ruote.
	_add(root, _box(Vector3(0.46, 0.10, 0.52)), palette["wood"],
		_xf(Vector3(0, 0.16, 0)))
	for side in [-1.0, 1.0]:
		_add(root, _cylinder(0.15, 0.05), palette["wood"],
			_xf(Vector3(side * 0.26, 0.15, -0.06), Vector3(0, 0, 90)))
	# Montante e braccia dell'arco, aperte a V verso il bersaglio.
	_add(root, _box(Vector3(0.10, 0.26, 0.10)), palette["wood"],
		_xf(Vector3(0, 0.32, 0.02)))
	for side in [-1.0, 1.0]:
		_add(root, _box(Vector3(0.34, 0.05, 0.05)), palette["metal"],
			_xf(Vector3(side * 0.19, 0.44, 0.12), Vector3(0, side * 22.0, 0)))
	# Corda e dardo incoccato.
	_add(root, _box(Vector3(0.60, 0.015, 0.015)), palette["cloth"],
		_xf(Vector3(0, 0.44, 0.02)))
	_add(root, _cylinder(0.022, 0.42), palette["metal"],
		_xf(Vector3(0, 0.44, 0.20), Vector3(90, 0, 0)))
	_add(root, _cone(0.045, 0.09), palette["metal"],
		_xf(Vector3(0, 0.44, 0.42), Vector3(90, 0, 0)))


## L'equite: cavallo, lancia lunga e scudo ovale. La lancia sporge oltre la
## cella e segnala la direzione di carica.
static func _build_equites(root: Node3D, palette: Dictionary) -> void:
	_horse(root, palette)
	var rider := Node3D.new()
	rider.position = Vector3(0, 0.52, -0.02)
	root.add_child(rider)
	_humanoid(rider, palette, {"tunic": palette["primary"], "scale": 0.80, "legs": false})
	# Hasta: lunga, tenuta orizzontale in avanti.
	_add(rider, _cylinder(0.016, 0.72), palette["wood"],
		_xf(Vector3(0.20, 0.34, 0.16), Vector3(78, 0, 0)))
	_add(rider, _cone(0.035, 0.10), palette["metal"],
		_xf(Vector3(0.20, 0.42, 0.51), Vector3(78, 0, 0)))
	# Parma: scudo ovale, schiacciato per leggersi dall'alto.
	_add(rider, _cylinder(0.15, 0.04), palette["secondary"],
		_xf(Vector3(-0.20, 0.30, 0.06), Vector3(0, 0, 90)))


# --------------------------------------------------------------------------
# Figure galliche
# --------------------------------------------------------------------------

## Il guerriero del clan combatte quasi nudo: braghe nei colori della tribù,
## torque al collo, capelli calcinati dritti. La sagoma è stretta e alta, il
## contrario del legionario rannicchiato dietro lo scudo.
static func _build_clansman(root: Node3D, palette: Dictionary) -> void:
	# Il busto porta il colore della tribù invece di restare nudo: a torso
	# scoperto la figura era una macchia chiara che dall'alto sembrava distesa,
	# perché mancava un blocco verticale a reggerne la lettura. Restano le
	# braccia scoperte, i capelli e il torque a dire che non è un legionario.
	_humanoid(root, palette, {"tunic": palette["primary"], "helmet": false, "shoulders": 0.34})
	var breeches: Color = palette["primary"]
	_add(root, _box(Vector3(0.23, 0.20, 0.18)), breeches.darkened(0.3),
		_xf(Vector3(0, 0.15, 0)))
	var hair: Color = palette["secondary"]
	_add(root, _cone(0.10, 0.17), hair.lightened(0.30),
		_xf(Vector3(0, 0.70, -0.01)))
	_torque(root, palette)
	_long_sword(root, palette, 0.42)
	_round_shield(root, palette, Vector3(-0.21, 0.40, 0.07), 0.15, palette["primary"])


## Il cacciatore ha lo stesso arco del Sagittario, ma tutto il resto lo separa:
## cappuccio calato, mantello corto, nessuna corazza.
static func _build_gaul_hunter(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "helmet": false})
	_add(root, _tapered(0.108, 0.05, 0.17), palette["wood"],
		_xf(Vector3(0, 0.69, -0.01)))
	var cloak: Color = palette["wood"]
	_cloak(root, cloak.darkened(0.15), 0.42, 0.34)
	_bow(root, palette, Vector3(0.03, 0.46, 0.13))
	_add(root, _cylinder(0.05, 0.26), palette["wood"],
		_xf(Vector3(-0.15, 0.44, -0.13), Vector3(0, 0, 22)))


## Il druido: veste chiara, cappuccio verde e soprattutto le corna di cervo,
## che dall'alto sono la sagoma più riconoscibile dell'esercito gallico.
static func _build_gaul_druid(root: Node3D, palette: Dictionary) -> void:
	_robed(root, palette, palette["primary"])
	var antler: Color = palette["wood"]
	_antlers(root, antler.lightened(0.35), 0.84)
	_add(root, _cylinder(0.018, 0.68), palette["wood"],
		_xf(Vector3(0.21, 0.40, 0.04), Vector3(10, 0, -8)))
	var orb := _add(root, _sphere(0.062), Color(0.62, 0.92, 0.68),
		_xf(Vector3(0.27, 0.77, 0.09)))
	_make_emissive(orb, Color(0.50, 0.95, 0.70), 1.4)
	# Falcetto d'oro alla cintura: piccolo, ma è l'attributo del druido.
	_add(root, _box(Vector3(0.13, 0.03, 0.02)), palette["secondary"],
		_xf(Vector3(-0.17, 0.34, 0.08), Vector3(0, 0, 34)))


## Il carro falcato è la sagoma più larga del gioco: tiro davanti, cassone
## dietro, lame che sporgono dai mozzi. Occupa quasi tutta la cella apposta —
## è una macchina fatta per travolgere una fila intera.
static func _build_chariot(root: Node3D, palette: Dictionary) -> void:
	var team := Node3D.new()
	team.name = "Tiro"
	team.position = Vector3(0, 0, 0.34)
	root.add_child(team)
	_horse(team, palette)

	# Timone che collega il tiro al cassone.
	_add(root, _box(Vector3(0.06, 0.05, 0.44)), palette["wood"],
		_xf(Vector3(0, 0.34, 0.06)))

	var cart := Node3D.new()
	cart.name = "Cassone"
	cart.position = Vector3(0, 0, -0.26)
	root.add_child(cart)
	_add(cart, _box(Vector3(0.40, 0.09, 0.34)), palette["wood"],
		_xf(Vector3(0, 0.30, 0)))
	# Parapetto anteriore in vimini.
	var wicker: Color = palette["secondary"]
	_add(cart, _box(Vector3(0.40, 0.22, 0.05)), wicker.darkened(0.25),
		_xf(Vector3(0, 0.42, 0.15)))

	var rim: Color = palette["wood"]
	for side in [-1.0, 1.0]:
		_add(cart, _cylinder(0.20, 0.05), rim.darkened(0.25),
			_xf(Vector3(side * 0.24, 0.20, 0), Vector3(0, 0, 90)))
		# Lama falcata: sporge dal mozzo verso l'esterno, sul piano del terreno.
		# È la parte che va vista dall'alto, quindi è orizzontale e lunga.
		_add(cart, _box(Vector3(0.18, 0.03, 0.07)), palette["metal"],
			_xf(Vector3(side * 0.32, 0.20, 0)))
		_add(cart, _cone(0.042, 0.09), palette["metal"],
			_xf(Vector3(side * 0.44, 0.20, 0), Vector3(0, 0, side * -90.0)))

	var driver := Node3D.new()
	driver.position = Vector3(0, 0.34, -0.24)
	root.add_child(driver)
	_humanoid(driver, palette, {"tunic": palette["primary"], "scale": 0.78, "legs": false})


## Il campione è la versione pesante del guerriero: scudo ovale grande, spadone
## ed elmo col cimiero a cinghiale, insegna dei capi gallici.
static func _build_gaul_champion(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "scale": 1.12, "shoulders": 0.36})
	_torque(root, palette)
	_long_sword(root, palette, 0.46)
	# Scudo ovale: un disco allungato in verticale, diverso dal rettangolo romano.
	var shield := _add(root, _cylinder(0.19, 0.05), palette["secondary"],
		_xf(Vector3(-0.23, 0.42, 0.06), Vector3(90, 0, 0)))
	shield.scale = Vector3(1.0, 1.0, 1.35)
	_add(root, _sphere(0.05), palette["metal"],
		_xf(Vector3(-0.27, 0.42, 0.06), Vector3.ZERO, Vector3(0.6, 1, 1)))
	# Cimiero: il corpo del cinghiale sulla calotta, col muso in avanti.
	var boar: Color = palette["metal"]
	_add(root, _box(Vector3(0.05, 0.09, 0.22)), boar.darkened(0.2),
		_xf(Vector3(0, 0.78, -0.01)))
	_add(root, _cone(0.045, 0.10), boar.darkened(0.2),
		_xf(Vector3(0, 0.80, 0.12), Vector3(70, 0, 0)))


## Il Solduros è la guardia giurata del capo: un fante pesante, non un
## cavaliere, perché il giuramento dei Solduri li lega a terra, al fianco dei
## compagni, non in sella. Porta comunque il vessillo della tribù — piantato
## sul dorso invece che sulla sella — che resta l'unica asta verticale della
## sagoma vista dall'alto, e l'elmo cornuto che segnalava il capo in battaglia.
static func _build_solduros(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "scale": 1.14, "shoulders": 0.36})
	var cloak: Color = palette["primary"]
	_cloak(root, cloak.darkened(0.25), 0.34, 0.44)
	_torque(root, palette)
	_horns(root, palette["cloth"], 0.70)
	_long_sword(root, palette, 0.46)
	# Scudo ovale, stretto al corpo come nella parete di scudi dei Solduri.
	var shield := _add(root, _cylinder(0.19, 0.05), palette["secondary"],
		_xf(Vector3(-0.23, 0.42, 0.06), Vector3(90, 0, 0)))
	shield.scale = Vector3(1.0, 1.0, 1.35)
	_add(root, _sphere(0.05), palette["metal"],
		_xf(Vector3(-0.27, 0.42, 0.06), Vector3.ZERO, Vector3(0.6, 1, 1)))
	# Insegna sul dorso: asta, drappo e il cinghiale in cima.
	_add(root, _cylinder(0.016, 0.66), palette["wood"],
		_xf(Vector3(0, 0.30, -0.22), Vector3(-8, 0, 0)))
	_add(root, _box(Vector3(0.03, 0.16, 0.18)), palette["secondary"],
		_xf(Vector3(0, 0.55, -0.30)))
	_add(root, _box(Vector3(0.05, 0.06, 0.14)), palette["secondary"],
		_xf(Vector3(0, 0.68, -0.24)))


## Il fromboliere fa roteare la fionda sopra la testa: il cerchio di corda è un
## anello netto in pianta, e nessun'altra unità ha un cerchio sospeso. È lo
## stesso ragionamento per cui l'arco è stato disteso — solo che qui il cerchio
## è il segno giusto, non un errore di lettura.
static func _build_gaul_slinger(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "helmet": false})
	# Fascia: un anello attorno alla fronte, non una placca sulla calotta —
	# vista dall'alto una placca diventa un quadrato che nasconde la testa.
	_add(root, _torus(0.082, 0.098), palette["secondary"],
		_xf(Vector3(0, 0.64, 0)))
	_whirling_sling(root, palette, Vector3(0.05, 0.92, 0.02), 0.25, 0.0)
	# Sacca di pietre alla cintura.
	_add(root, _sphere(0.075), palette["wood"],
		_xf(Vector3(-0.18, 0.30, -0.02), Vector3.ZERO, Vector3(1.0, 1.2, 0.8)))


# --------------------------------------------------------------------------
# Figure teutoniche
# --------------------------------------------------------------------------

## Il lanciere: lancia lunga puntata in avanti e scudo rotondo. La lancia esce
## dalla cella e dice a colpo d'occhio da che parte guarda la formazione.
static func _build_teuton_spearman(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "helmet": false})
	_nasal_helmet(root, palette)
	_round_shield(root, palette, Vector3(-0.22, 0.45, 0.09), 0.17, palette["secondary"])
	_add(root, _cylinder(0.018, 0.76), palette["wood"],
		_xf(Vector3(0.23, 0.46, 0.14), Vector3(74, 0, 0)))
	_add(root, _cone(0.036, 0.12), palette["metal"],
		_xf(Vector3(0.23, 0.56, 0.50), Vector3(74, 0, 0)))


## Anche il teutonico tira di fionda, ma la fa girare bassa e di lato, e porta
## la bisaccia a tracolla: le due frombole restano distinguibili senza dover
## leggere il colore.
static func _build_teuton_skirmisher(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "helmet": false})
	_add(root, _tapered(0.10, 0.06, 0.14), palette["wood"],
		_xf(Vector3(0, 0.68, -0.01)))
	_whirling_sling(root, palette, Vector3(0.26, 0.52, 0.10), 0.19, 34.0)
	# Tracolla e bisaccia delle pietre.
	_add(root, _box(Vector3(0.06, 0.26, 0.04)), palette["wood"],
		_xf(Vector3(0, 0.46, 0), Vector3(0, 0, 28)))
	var bag: Color = palette["wood"]
	_add(root, _box(Vector3(0.16, 0.14, 0.10)), bag.lightened(0.15),
		_xf(Vector3(-0.19, 0.31, -0.02)))


## La scudiera para: lo scudo è grande e portato davanti al corpo, non di
## fianco. In pianta è un disco pieno che copre la figura, che è esattamente
## quello che fa in battaglia.
static func _build_shieldmaiden(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "shoulders": 0.30, "helmet": false})
	_add(root, _tapered(0.098, 0.088, 0.12), palette["metal"],
		_xf(Vector3(0, 0.66, 0)))
	# Treccia lunga sulla schiena.
	var braid: Color = palette["secondary"]
	_add(root, _cylinder(0.035, 0.26), braid.lightened(0.2),
		_xf(Vector3(0, 0.52, -0.11), Vector3(16, 0, 0)))
	_round_shield(root, palette, Vector3(-0.06, 0.42, 0.20), 0.21, palette["secondary"])
	_add(root, _box(Vector3(0.035, 0.28, 0.02)), palette["metal"],
		_xf(Vector3(0.25, 0.54, -0.02), Vector3(-16, 0, -12)))


## La veggente: veste azzurra, bastone runico e il corvo sulla spalla. Il corvo
## è piccolo ma sporge dalla sagoma, ed è ciò che la separa dal druido gallico.
static func _build_seeress(root: Node3D, palette: Dictionary) -> void:
	_robed(root, palette, palette["primary"])
	_add(root, _cylinder(0.018, 0.70), palette["wood"],
		_xf(Vector3(0.21, 0.41, 0.04), Vector3(8, 0, -7)))
	# Anello runico in cima al bastone, invece del globo del druido.
	var runes := _add(root, _torus(0.055, 0.085), Color(0.70, 0.82, 1.0),
		_xf(Vector3(0.27, 0.80, 0.08), Vector3(90, 0, 0)))
	_make_emissive(runes, Color(0.55, 0.75, 1.0), 1.5)
	var raven := Color(0.16, 0.17, 0.22)
	_add(root, _box(Vector3(0.08, 0.08, 0.15)), raven,
		_xf(Vector3(-0.16, 0.70, -0.02), Vector3(-12, 0, 0)))
	_add(root, _sphere(0.042), raven, _xf(Vector3(-0.16, 0.77, 0.05)))
	_add(root, _cone(0.02, 0.06), palette["secondary"],
		_xf(Vector3(-0.16, 0.77, 0.10), Vector3(90, 0, 0)))


## L'ariete è coperto da una tettoia — è ciò che lo distingue dalla balista
## romana, che invece è aperta — e la trave termina con una testa di montone.
static func _build_battering_ram(root: Node3D, palette: Dictionary) -> void:
	var frame: Color = palette["wood"]
	_add(root, _box(Vector3(0.46, 0.10, 0.52)), frame.lightened(0.18),
		_xf(Vector3(0, 0.13, 0)))
	for side in [-1.0, 1.0]:
		_add(root, _cylinder(0.13, 0.05), frame.darkened(0.3),
			_xf(Vector3(side * 0.26, 0.13, -0.04), Vector3(0, 0, 90)))
		_add(root, _box(Vector3(0.05, 0.34, 0.05)), frame,
			_xf(Vector3(side * 0.19, 0.35, -0.10)))
		# Funi di sospensione della trave.
		_add(root, _box(Vector3(0.02, 0.14, 0.02)), palette["cloth"],
			_xf(Vector3(side * 0.16, 0.52, -0.06)))
	_add(root, _cylinder(0.075, 0.60), frame.darkened(0.45),
		_xf(Vector3(0, 0.45, 0.12), Vector3(90, 0, 0)))
	# Testa di montone in ferro, con le corna avvolte ai lati.
	var iron: Color = palette["metal"]
	_add(root, _cylinder(0.10, 0.13), iron,
		_xf(Vector3(0, 0.45, 0.44), Vector3(90, 0, 0)))
	for side in [-1.0, 1.0]:
		_add(root, _torus(0.035, 0.075), iron.darkened(0.2),
			_xf(Vector3(side * 0.09, 0.45, 0.42), Vector3(0, 0, 90)))
	# Tettoia a due falde: la firma dell'ariete coperto. Copre solo la metà
	# posteriore — a piena lunghezza nascondeva trave e testa, e dall'alto la
	# macchina diventava una tenda blu senza attributi.
	_add(root, _prism(Vector3(0.44, 0.15, 0.32), 0.5), palette["primary"],
		_xf(Vector3(0, 0.64, -0.14)))


## Arminio, il capo dell'imboscata: pelliccia di lupo sul capo, due lance corte
## e mantello. Più alto di ogni altro fante, così si trova subito nella mischia.
static func _build_arminius(root: Node3D, palette: Dictionary) -> void:
	_humanoid(root, palette, {"tunic": palette["primary"], "scale": 1.14, "helmet": false})
	var cloak: Color = palette["primary"]
	_cloak(root, cloak.darkened(0.3), 0.44, 0.46)
	# Cappuccio di pelo con le orecchie: la testa di lupo dell'insegna.
	var pelt: Color = palette["wood"]
	pelt = pelt.lightened(0.2)
	_add(root, _sphere(0.11), pelt,
		_xf(Vector3(0, 0.70, -0.01), Vector3.ZERO, Vector3(1.0, 0.85, 1.0)))
	for side in [-1.0, 1.0]:
		_add(root, _cone(0.04, 0.10), pelt,
			_xf(Vector3(side * 0.07, 0.80, -0.01), Vector3(0, 0, side * 18.0)))
	# Due lance corte, una per mano: l'arma dell'imboscata nel bosco.
	for side in [-1.0, 1.0]:
		_add(root, _cylinder(0.015, 0.52), palette["wood"],
			_xf(Vector3(side * 0.26, 0.50, 0.10), Vector3(62, 0, side * 12.0)))
		_add(root, _cone(0.030, 0.10), palette["metal"],
			_xf(Vector3(side * 0.28, 0.62, 0.32), Vector3(62, 0, side * 12.0)))


# --------------------------------------------------------------------------
# Figure di ripiego, una per archetipo
# --------------------------------------------------------------------------

## Modello generico usato da tutte le unità che non hanno ancora una figura
## dedicata. Non è un segnaposto neutro: legge le classi e costruisce comunque
## la silhouette giusta per il ruolo, tinta con la palette della civiltà. Un
## cacciatore gallico e un fromboliere teutonico sono già distinguibili fra
## loro, anche se non ancora dal Sagittario romano.
static func _build_archetype(root: Node3D, palette: Dictionary, archetype: String) -> void:
	match archetype:
		"archer":
			_humanoid(root, palette, {"tunic": palette["primary"], "helmet": false})
			# Cappuccio d'accento: distingue l'arciere generico dal Sagittario
			# romano, che invece va a capo scoperto.
			_add(root, _tapered(0.105, 0.055, 0.15), palette["secondary"],
				_xf(Vector3(0, 0.68, -0.01)))
			_bow(root, palette, Vector3(0.03, 0.46, 0.13))
		"cavalry":
			_horse(root, palette)
			var rider := Node3D.new()
			rider.position = Vector3(0, 0.52, -0.02)
			root.add_child(rider)
			_humanoid(rider, palette, {"tunic": palette["primary"], "scale": 0.80, "legs": false})
			_add(rider, _cylinder(0.016, 0.62), palette["wood"],
				_xf(Vector3(0.20, 0.34, 0.12), Vector3(74, 0, 0)))
		"siege":
			# Piattaforma con trave d'ariete: bassa e larga come la balista, ma
			# senza braccia, così le due macchine restano distinguibili.
			# I tre legni hanno tinte diverse — telaio chiaro, montanti medi,
			# trave scura — perché in un solo marrone la macchina diventava una
			# massa informe.
			var frame: Color = palette["wood"]
			_add(root, _box(Vector3(0.44, 0.11, 0.50)), frame.lightened(0.18),
				_xf(Vector3(0, 0.13, 0)))
			for side in [-1.0, 1.0]:
				_add(root, _cylinder(0.13, 0.05), frame.darkened(0.3),
					_xf(Vector3(side * 0.25, 0.13, -0.04), Vector3(0, 0, 90)))
			for side in [-1.0, 1.0]:
				_add(root, _box(Vector3(0.05, 0.34, 0.05)), frame,
					_xf(Vector3(side * 0.17, 0.36, -0.12), Vector3(-16, 0, 0)))
			# Funi di sospensione: legano la trave ai montanti e spiegano perché
			# resta sollevata.
			for side in [-1.0, 1.0]:
				_add(root, _box(Vector3(0.02, 0.16, 0.02)), palette["cloth"],
					_xf(Vector3(side * 0.15, 0.53, -0.02)))
			_add(root, _cylinder(0.075, 0.62), frame.darkened(0.45),
				_xf(Vector3(0, 0.46, 0.12), Vector3(90, 0, 0)))
			_add(root, _cylinder(0.10, 0.12), palette["metal"],
				_xf(Vector3(0, 0.46, 0.44), Vector3(90, 0, 0)))
		"druid":
			_add(root, _tapered(0.25, 0.12, 0.54), palette["cloth"],
				_xf(Vector3(0, 0.27, 0)))
			_add(root, _box(Vector3(0.24, 0.20, 0.17)), palette["primary"],
				_xf(Vector3(0, 0.60, 0)))
			_add(root, _sphere(0.078), palette["skin"], _xf(Vector3(0, 0.77, 0)))
			# Cappuccio.
			_add(root, _tapered(0.115, 0.05, 0.17), palette["primary"],
				_xf(Vector3(0, 0.80, -0.02)))
			# Bastone con globo luminoso: il segnale che l'unità lancia magie.
			_add(root, _cylinder(0.018, 0.66), palette["wood"],
				_xf(Vector3(0.21, 0.40, 0.04), Vector3(10, 0, -8)))
			var orb := _add(root, _sphere(0.06), Color(0.65, 0.90, 0.75),
				_xf(Vector3(0.27, 0.76, 0.09)))
			_make_emissive(orb, Color(0.50, 0.95, 0.70), 1.3)
		"berserker":
			# Torso nudo, spalle larghe, due asce: massa concentrata in alto,
			# che dall'alto si legge come una sagoma più larga del normale.
			_humanoid(root, palette, {
				"tunic": palette["skin"], "helmet": false, "shoulders": 0.38, "scale": 1.06,
			})
			# Una fascia nel colore della civiltà attraversa il petto: senza,
			# il torso nudo e le braccia rendevano l'unità una macchia chiara
			# indistinguibile a colpo d'occhio.
			_add(root, _box(Vector3(0.42, 0.09, 0.22)), palette["primary"],
				_xf(Vector3(0, 0.46, 0), Vector3(0, 0, 22)))
			# Capigliatura folta al posto dell'elmo, scura per staccare dalla
			# pelle invece di fondersi con essa.
			var hair: Color = palette["secondary"]
			_add(root, _sphere(0.105), hair.darkened(0.5),
				_xf(Vector3(0, 0.68, -0.02), Vector3.ZERO, Vector3(1.0, 0.7, 1.0)))
			# Due asce a doppia lama: le teste sono volutamente sovradimensionate,
			# dall'alto sono l'unica parte dell'arma che si vede davvero.
			for side in [-1.0, 1.0]:
				_add(root, _cylinder(0.018, 0.36), palette["wood"],
					_xf(Vector3(side * 0.27, 0.48, 0.06), Vector3(24, 0, side * 20.0)))
				_add(root, _box(Vector3(0.10, 0.17, 0.05)), palette["metal"],
					_xf(Vector3(side * 0.35, 0.66, 0.11), Vector3(24, 0, side * 20.0)))
				_add(root, _box(Vector3(0.17, 0.06, 0.05)), palette["metal"],
					_xf(Vector3(side * 0.35, 0.66, 0.11), Vector3(24, 0, side * 20.0)))
		_:
			# Fanteria pesante: lancia e scudo, la formazione di base di ogni
			# civiltà.
			_humanoid(root, palette, {"tunic": palette["primary"]})
			_add(root, _box(Vector3(0.05, 0.40, 0.30)), palette["secondary"],
				_xf(Vector3(-0.21, 0.40, 0.04)))
			_add(root, _cylinder(0.017, 0.62), palette["wood"],
				_xf(Vector3(0.22, 0.44, 0.02), Vector3(12, 0, -6)))
			_add(root, _cone(0.032, 0.10), palette["metal"],
				_xf(Vector3(0.28, 0.78, 0.09), Vector3(12, 0, -6)))


# --------------------------------------------------------------------------
# Componenti condivisi
# --------------------------------------------------------------------------

## Corpo umanoide di base. Le opzioni permettono agli archetipi di variarne i
## pezzi senza duplicare l'intera funzione; `legs: false` serve ai cavalieri,
## che le gambe le hanno lungo i fianchi del cavallo e non sotto il busto.
static func _humanoid(parent: Node3D, palette: Dictionary, opts: Dictionary = {}) -> void:
	var body := Node3D.new()
	body.name = "Body"
	var scale_factor: float = float(opts.get("scale", 1.0))
	body.scale = Vector3.ONE * scale_factor
	parent.add_child(body)

	var tunic: Color = opts.get("tunic", palette["primary"])
	var shoulders: float = float(opts.get("shoulders", 0.32))

	if bool(opts.get("legs", true)):
		for side in [-1.0, 1.0]:
			_add(body, _box(Vector3(0.10, 0.26, 0.13)), palette["cloth"],
				_xf(Vector3(side * 0.07, 0.13, 0)))

	# Busto: leggermente rastremato verso l'alto, così le spalle sporgono.
	_add(body, _box(Vector3(shoulders, 0.30, 0.20)), tunic,
		_xf(Vector3(0, 0.41, 0)))
	# Cintura.
	_add(body, _box(Vector3(shoulders + 0.02, 0.05, 0.22)), palette["wood"],
		_xf(Vector3(0, 0.29, 0)))
	# Braccia.
	for side in [-1.0, 1.0]:
		_add(body, _box(Vector3(0.08, 0.24, 0.09)), palette["skin"],
			_xf(Vector3(side * (shoulders * 0.5 + 0.04), 0.42, 0.02), Vector3(0, 0, side * -6.0)))
	# Testa.
	_add(body, _sphere(0.082), palette["skin"], _xf(Vector3(0, 0.63, 0.01)))

	if bool(opts.get("helmet", true)):
		_add(body, _tapered(0.098, 0.085, 0.13), palette["metal"],
			_xf(Vector3(0, 0.66, 0)))
		# Paranuca: sporge dietro, aiuta a capire dove guarda l'unità.
		_add(body, _box(Vector3(0.17, 0.07, 0.04)), palette["metal"],
			_xf(Vector3(0, 0.60, -0.09)))


## Scudo rettangolare romano, con la borchia centrale in bronzo.
static func _scutum(parent: Node3D, palette: Dictionary) -> void:
	_add(parent, _box(Vector3(0.06, 0.42, 0.32)), palette["primary"],
		_xf(Vector3(-0.22, 0.40, 0.04)))
	_add(parent, _box(Vector3(0.02, 0.34, 0.24)), palette["secondary"],
		_xf(Vector3(-0.26, 0.40, 0.04)))
	_add(parent, _sphere(0.05), palette["secondary"],
		_xf(Vector3(-0.27, 0.40, 0.04), Vector3.ZERO, Vector3(0.5, 1.0, 1.0)))


static func _gladius(parent: Node3D, palette: Dictionary) -> void:
	_add(parent, _box(Vector3(0.035, 0.30, 0.02)), palette["metal"],
		_xf(Vector3(0.24, 0.46, 0.10), Vector3(28, 0, -14)))
	_add(parent, _box(Vector3(0.09, 0.03, 0.03)), palette["secondary"],
		_xf(Vector3(0.22, 0.33, 0.04), Vector3(28, 0, -14)))


## Cresta dell'elmo. Quella trasversale (`transverse`) è il segno del
## centurione: attraversa l'elmo da orecchio a orecchio invece che da fronte a
## nuca, e dall'alto cambia completamente la sagoma della testa.
static func _crest(parent: Node3D, palette: Dictionary, transverse: bool) -> void:
	var size := Vector3(0.26, 0.09, 0.03) if transverse else Vector3(0.03, 0.09, 0.24)
	_add(parent, _box(size), palette["primary"],
		_xf(Vector3(0, 0.77, -0.01)))


## Arco teso, costruito segmento per segmento lungo una parabola.
##
## Due scelte contro-intuitive, entrambe imposte dalla vista dall'alto. Prima:
## niente toro: un anello, per quanto schiacciato, dall'alto resta un cerchio e
## sembra una ruota, mentre di un arco si devono vedere le due punte libere.
## Seconda: l'arco è disteso sul piano orizzontale invece che in verticale come
## lo terrebbe un arciere vero. Con le braccia verticali la curva si accorcia
## fino a sparire sotto la camera e l'arma diventa un trattino; sdraiata, la
## curva resta intera e l'arciere si riconosce da qualsiasi distanza. È la
## stessa licenza che si prendono i giochi in pianta, per la stessa ragione.
static func _bow(parent: Node3D, palette: Dictionary, position: Vector3) -> void:
	const SEGMENTS := 7
	const HALF_SPAN := 0.24
	const BULGE := 0.13

	for i in SEGMENTS:
		var t := -1.0 + 2.0 * float(i) / float(SEGMENTS - 1)
		var offset := Vector3(t * HALF_SPAN, 0.0, BULGE * (1.0 - t * t))
		# Inclinazione della tacca: la tangente della parabola nel punto.
		var angle := -rad_to_deg(atan2(-2.0 * BULGE * t, HALF_SPAN))
		_add(parent, _box(Vector3(2.2 * HALF_SPAN / float(SEGMENTS - 1), 0.028, 0.028)),
			palette["wood"], _xf(position + offset, Vector3(0, angle, 0)))

	# Corda: è dritta, ed è il contrasto con la curva del legno a rendere
	# leggibile che l'arco è teso.
	_add(parent, _box(Vector3(2.0 * HALF_SPAN, 0.012, 0.012)), palette["cloth"],
		_xf(position))
	# Freccia incoccata, puntata in avanti.
	_add(parent, _cylinder(0.011, 0.32), palette["cloth"],
		_xf(position + Vector3(0, 0.01, 0.12), Vector3(90, 0, 0)))
	_add(parent, _cone(0.026, 0.07), palette["metal"],
		_xf(position + Vector3(0, 0.01, 0.31), Vector3(90, 0, 0)))


## Cavallo: corpo, collo, testa e quattro zampe. Allunga la sagoma lungo l'asse
## di marcia, che è ciò che rende la cavalleria riconoscibile dall'alto.
static func _horse(parent: Node3D, palette: Dictionary) -> void:
	var horse := Node3D.new()
	horse.name = "Horse"
	parent.add_child(horse)
	var hide: Color = palette["wood"]
	hide = hide.lightened(0.12)
	var mane: Color = palette["secondary"]
	mane = mane.darkened(0.35)
	var hoof := hide.darkened(0.18)

	_add(horse, _box(Vector3(0.26, 0.28, 0.64)), hide, _xf(Vector3(0, 0.44, 0)))
	# Collo e testa, protesi in avanti e in basso.
	_add(horse, _box(Vector3(0.16, 0.30, 0.16)), hide,
		_xf(Vector3(0, 0.56, 0.30), Vector3(38, 0, 0)))
	_add(horse, _box(Vector3(0.13, 0.13, 0.24)), hide,
		_xf(Vector3(0, 0.68, 0.44), Vector3(72, 0, 0)))
	# Criniera e coda, nel colore secondario della civiltà.
	_add(horse, _box(Vector3(0.05, 0.10, 0.30)), mane,
		_xf(Vector3(0, 0.68, 0.26), Vector3(38, 0, 0)))
	_add(horse, _box(Vector3(0.06, 0.22, 0.06)), mane,
		_xf(Vector3(0, 0.46, -0.33), Vector3(-24, 0, 0)))
	# Zampe.
	for x in [-0.10, 0.10]:
		for z in [-0.22, 0.22]:
			_add(horse, _box(Vector3(0.08, 0.32, 0.08)), hoof,
				_xf(Vector3(x, 0.16, z)))
	# Gualdrappa: la stoffa colorata sul dorso lega il cavallo alla civiltà.
	_add(horse, _box(Vector3(0.30, 0.05, 0.34)), palette["primary"],
		_xf(Vector3(0, 0.57, -0.04)))


## Corpo in veste lunga, senza gambe né braccia distinte: la base di druidi e
## veggenti. In pianta è un cerchio pieno, l'opposto di una sagoma armata, ed è
## così che si riconosce un lanciatore di incantesimi a distanza.
static func _robed(parent: Node3D, palette: Dictionary, hood_color: Color) -> void:
	_add(parent, _tapered(0.25, 0.12, 0.54), palette["cloth"],
		_xf(Vector3(0, 0.27, 0)))
	_add(parent, _box(Vector3(0.24, 0.20, 0.17)), hood_color,
		_xf(Vector3(0, 0.60, 0)))
	_add(parent, _sphere(0.078), palette["skin"], _xf(Vector3(0, 0.77, 0)))
	_add(parent, _tapered(0.115, 0.05, 0.17), hood_color,
		_xf(Vector3(0, 0.80, -0.02)))


## Scudo rotondo con umbone centrale. `centre` è il centro del disco, che resta
## rivolto in avanti: di taglio non si vedrebbe.
static func _round_shield(parent: Node3D, palette: Dictionary, centre: Vector3,
		radius: float, face: Color) -> void:
	_add(parent, _cylinder(radius, 0.05), face, _xf(centre, Vector3(90, 0, 0)))
	_add(parent, _torus(radius * 0.88, radius), palette["metal"],
		_xf(centre + Vector3(0, 0, 0.015), Vector3(90, 0, 0)))
	_add(parent, _sphere(0.048), palette["metal"],
		_xf(centre + Vector3(0, 0, 0.03), Vector3.ZERO, Vector3(1, 1, 0.6)))


## Spada lunga celtica, tenuta obliqua sul fianco destro.
static func _long_sword(parent: Node3D, palette: Dictionary, length: float) -> void:
	_add(parent, _box(Vector3(0.04, length, 0.025)), palette["metal"],
		_xf(Vector3(0.25, 0.34 + length * 0.45, 0.08), Vector3(20, 0, -16)))
	_add(parent, _box(Vector3(0.13, 0.03, 0.035)), palette["wood"],
		_xf(Vector3(0.21, 0.33, 0.02), Vector3(20, 0, -16)))


## Torque: il collare rigido dei Galli. Sta in piano attorno al collo, quindi
## il toro non va ruotato — nella posa base giace già sul piano orizzontale.
static func _torque(parent: Node3D, palette: Dictionary) -> void:
	_add(parent, _torus(0.055, 0.078), palette["secondary"],
		_xf(Vector3(0, 0.55, 0)))


## Mantello: un trapezio appiattito che si apre dietro le spalle.
static func _cloak(parent: Node3D, color: Color, height: float, width: float) -> void:
	_add(parent, _prism(Vector3(width, height, 0.05), 0.35), color,
		_xf(Vector3(0, height * 0.78, -0.14), Vector3(12, 0, 0)))


## Corna da elmo: due coni aperti a V. Sporgono oltre la testa, quindi si
## leggono anche quando la figura è di scorcio.
static func _horns(parent: Node3D, color: Color, y: float) -> void:
	for side in [-1.0, 1.0]:
		_add(parent, _cone(0.036, 0.20), color,
			_xf(Vector3(side * 0.09, y + 0.10, 0), Vector3(0, 0, side * -42.0)))


## Palco di corna di cervo: due aste con due punte ciascuna. È la sagoma più
## complessa dell'intero set, e vale il costo — nessun'altra unità le ha.
static func _antlers(parent: Node3D, color: Color, y: float) -> void:
	for side in [-1.0, 1.0]:
		_add(parent, _cylinder(0.016, 0.22), color,
			_xf(Vector3(side * 0.07, y + 0.09, -0.01), Vector3(-10, 0, side * -26.0)))
		_add(parent, _cylinder(0.012, 0.13), color,
			_xf(Vector3(side * 0.15, y + 0.20, 0.02), Vector3(-34, 0, side * -46.0)))
		_add(parent, _cylinder(0.012, 0.12), color,
			_xf(Vector3(side * 0.12, y + 0.22, -0.08), Vector3(30, 0, side * -18.0)))


## Fionda in rotazione: l'anello è la corda mossa, la sfera è la pietra. Un
## cerchio sospeso non appartiene a nessun'altra unità, quindi in pianta
## identifica il fromboliere da solo. `tilt` inclina il piano di rotazione.
static func _whirling_sling(parent: Node3D, palette: Dictionary, centre: Vector3,
		radius: float, tilt: float) -> void:
	_add(parent, _torus(radius - 0.014, radius), palette["cloth"],
		_xf(centre, Vector3(tilt, 0, 0)))
	var stone: Color = palette["metal"]
	_add(parent, _sphere(0.042), stone.darkened(0.25),
		_xf(centre + Vector3(radius * 0.98, 0, 0)))


## Elmo conico con nasale: la testa dei Teutoni, diversa dalla calotta romana.
static func _nasal_helmet(parent: Node3D, palette: Dictionary) -> void:
	_add(parent, _tapered(0.10, 0.03, 0.17), palette["metal"],
		_xf(Vector3(0, 0.69, 0)))
	_add(parent, _box(Vector3(0.03, 0.10, 0.02)), palette["metal"],
		_xf(Vector3(0, 0.63, 0.08)))


# --------------------------------------------------------------------------
# Primitive e utilità
# --------------------------------------------------------------------------

## Aggiunge una mesh come figlia e restituisce l'istanza, così il chiamante può
## ritoccarla (scala non uniforme, emissione) senza ricostruirne il trasform.
static func _add(parent: Node3D, mesh: Mesh, color: Color, xform: Transform3D) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(color)
	instance.transform = xform
	parent.add_child(instance)
	return instance


## Trasform da posizione, rotazione in gradi e scala: le rotazioni dei modelli
## si ragionano in gradi, e scriverle in radianti renderebbe illeggibili le
## funzioni qui sopra.
static func _xf(position: Vector3, rotation_degrees := Vector3.ZERO, scale := Vector3.ONE) -> Transform3D:
	var basis := Basis.from_euler(Vector3(
		deg_to_rad(rotation_degrees.x),
		deg_to_rad(rotation_degrees.y),
		deg_to_rad(rotation_degrees.z)))
	return Transform3D(basis.scaled(scale), position)


static func _material(color: Color) -> StandardMaterial3D:
	var key := color.to_html(true)
	if _materials.has(key):
		return _materials[key]
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	material.metallic = 0.0
	# Le figure sono piccole sullo schermo: senza specular il volume sparisce,
	# con troppo diventano lucide come plastica.
	material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	_materials[key] = material
	return material


## Rende emissivo un pezzo già aggiunto (fiamme, globi magici). Il materiale
## viene duplicato: quelli in cache sono condivisi e non vanno modificati.
static func _make_emissive(instance: MeshInstance3D, color: Color, energy: float) -> void:
	var material: StandardMaterial3D = instance.material_override.duplicate()
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	instance.material_override = material


static func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


static func _cylinder(radius: float, height: float) -> CylinderMesh:
	return _tapered(radius, radius, height)


static func _cone(radius: float, height: float) -> CylinderMesh:
	return _tapered(radius, 0.0, height)


## Cilindro con raggi diversi alle due basi: copre coni, tronchi di cono e
## cilindri con una sola funzione.
static func _tapered(bottom_radius: float, top_radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = bottom_radius
	mesh.top_radius = top_radius
	mesh.height = height
	# Otto lati bastano a queste dimensioni sullo schermo e tengono basso il
	# numero di vertici con decine di unità in campo.
	mesh.radial_segments = 8
	mesh.rings = 1
	return mesh


static func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	return mesh


static func _prism(size: Vector3, left_to_right: float) -> PrismMesh:
	var mesh := PrismMesh.new()
	mesh.size = size
	mesh.left_to_right = left_to_right
	return mesh


static func _torus(inner_radius: float, outer_radius: float) -> TorusMesh:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner_radius
	mesh.outer_radius = outer_radius
	mesh.rings = 10
	mesh.ring_segments = 5
	return mesh
