Metti qui i modelli .glb, uno per unita', con il nome file uguale all'id
dell'unita' in data/units.json. Nessuna registrazione da fare altrove: se il
file esiste, art/unit_models.gd lo usa al posto della figura procedurale per
quello stesso id; se manca, l'unita' ricade sulla figura procedurale come
oggi.

Id delle 20 unita' attuali (nome file atteso):

  legionarius.glb        caesar.glb              gaul_champion.glb
  centurio.glb           sagittarius.glb         vercingetorix.glb
  ballista.glb           equites.glb             gaul_slinger.glb
  vestal.glb             clansman.glb            teuton_spearman.glb
  gaul_hunter.glb         gaul_druid.glb          teuton_skirmisher.glb
  chariot.glb            shieldmaiden.glb        seeress.glb
  battering_ram.glb      arminius.glb

Orientamento: il modello base deve guardare verso +Z (asse Z positivo), come
le figure procedurali (vedi FORWARD in art/unit_models.gd) -- e' cosi' che
BattleBoard3D orienta le unita' verso il lato giusto del campo.

Scala: una cella della scacchiera vale 1.0 unita' di mondo; un fante
procedurale e' alto ~0.8. Un modello mille volte troppo grande o piccolo va
ridimensionato prima di essere esportato, non dopo in codice.

Dopo aver aggiunto i file, serve un import una tantum prima che Godot li veda
(vale anche per i test headless):

  godot --headless --path . --import
