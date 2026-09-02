Metti qui i modelli .glb, uno per unita', con il nome file uguale all'id
dell'unita' in data/units.json. Nessuna registrazione da fare altrove: se il
file esiste, art/unit_models.gd lo usa al posto della figura procedurale per
quello stesso id; se manca, l'unita' ricade sulla figura procedurale come
oggi.

Id delle 21 unita' attuali (nome file atteso):

  legionarius.glb        cataphractus.glb        gaul_champion.glb
  velites.glb             sagittarius.glb         solduros.glb
  centurio.glb            equites.glb             gaul_slinger.glb
  ballistarius.glb        clansman.glb            teuton_spearman.glb
  gaul_hunter.glb         gaul_druid.glb          teuton_skirmisher.glb
  chariot.glb            shieldmaiden.glb        seeress.glb
  battering_ram.glb      arminius.glb

Vale anche per i 2 eroi selezionabili nel menu (non sono unita', ma
build_hero() carica allo stesso modo res://models/<hero_id>.glb se presente):

  cesare.glb             vercingetorige.glb

Orientamento: il modello base deve guardare verso +Z (asse Z positivo), come
le figure procedurali (vedi FORWARD in art/unit_models.gd) -- e' cosi' che
BattleBoard3D orienta le unita' verso il lato giusto del campo.

Scala: una cella della scacchiera vale 1.0 unita' di mondo; un fante
procedurale e' alto ~0.8. build() normalizza comunque ogni .glb -- lo scala in
modo uniforme fino all'altezza dell'archetipo (height_of), lo poggia su y = 0 e
lo centra su x/z -- quindi un modello esportato in metri, centimetri o unita'
di Blender appare lo stesso alla dimensione giusta. Resta buona norma
esportarlo gia' vicino alla scala finale, ma non e' piu' obbligatorio.

Colori: se il .glb non porta colori (materiali tutti grigi, nessuna texture),
build() li assegna dai NOMI dei materiali -- nominali in italiano come nel
progetto ("Verde_Gallico", "Metallo_Ferro", "Cintura_Cuoio", "Capelli...",
"Mantello...", "Bracae...", "Bordo_Tunica", "Pelle...") e prendono la palette
della civilta'. Un materiale gia' colorato o con nome non riconosciuto resta
com'e'. Vedi _RECOLOR_KEYWORDS in art/unit_models.gd.

Dopo aver aggiunto i file, serve un import una tantum prima che Godot li veda
(vale anche per i test headless):

  godot --headless --path . --import
