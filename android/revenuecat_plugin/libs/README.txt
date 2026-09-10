Qui va godot-lib.<versione>.template_release.aar, scaricato dalla pagina delle
release di Godot (pacchetto Android / "Templates") per la STESSA versione del
motore usata dal progetto (4.7).

E' dichiarato compileOnly in build.gradle: serve a compilare il plugin, ma non
deve finire dentro l'.aar prodotto. La libreria Godot e' gia' dentro
l'applicazione esportata, e includerla due volte fa fallire il link.

Non e' versionato: pesa decine di MB ed e' un artefatto ufficiale, ricavabile in
qualsiasi momento.
