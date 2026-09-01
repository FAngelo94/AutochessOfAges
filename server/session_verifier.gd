class_name SessionVerifier
extends RefCounted

## Adattatore d'istanza attorno a SessionToken (statico) per il punto di
## iniezione di Matchmaker: `Matchmaker.new(verifier)` chiama `verifier.verify(token)`.
## Prende il posto del vecchio JwtVerifier. Nessuno stato: la verifica del token
## di sessione e' puramente locale (HMAC), non serve scaricare nessuna JWKS.


func verify(token: String) -> Dictionary:
	return SessionToken.verify(token)
