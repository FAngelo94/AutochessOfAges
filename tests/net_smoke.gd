extends SceneTree

## Smoke test del layer di rete — protocollo, matchmaking, match token
## (MULTIPLAYER_PLAN.md M4).
##
##   godot --headless --path . --script res://tests/net_smoke.gd
##
## In-process, senza socket reali: la logica del master vive tutta in Matchmaker
## (master_server.gd e' solo la pompa di frame), quindi si testa direttamente
## iniettando un verificatore di token finto e avanzando il timer con tick(delta).

var _passed := 0
var _failed := 0


## Verifier finto: accetta i token noti e li mappa a un uid.
class FakeVerifier extends RefCounted:
	var _map: Dictionary = {}
	func add(token: String, uid: String) -> void:
		_map[token] = uid
	func verify(token: String) -> Dictionary:
		if _map.has(token):
			return {"sub": _map[token], "username": "u_" + _map[token], "exp": 0}
		return {}


func _initialize() -> void:
	GameData.ensure_loaded()
	_test_protocol()
	_test_match_token()
	_test_session_token()
	_test_hello_rejects()
	_test_matchmaking_seal()
	_test_matchmaking_relobby()
	_test_spawn_signature()
	_test_hero_revalidation()
	_test_runner_full_match()
	_test_runner_spectate()
	_test_runner_spectate_ghost()
	_test_runner_reject_out_of_phase()
	_test_runner_reject_eliminated()
	_test_runner_spectate_requires_join()
	_test_runner_eliminated_counts_as_ready()
	_test_runner_reject_wrong_index()
	_test_runner_disconnect_reconnect()
	print("\n%d superati, %d falliti" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# --------------------------------------------------------------------------

func _test_protocol() -> void:
	section("Protocollo — encode/decode")

	check(Protocol.decode(PackedByteArray([1, 2, 3, 4, 5])).is_empty(),
		"decode(spazzatura) restituisce {}")
	check(Protocol.decode(PackedByteArray()).is_empty(),
		"decode(vuoto) restituisce {}")
	check(Protocol.decode(var_to_bytes(42)).is_empty(),
		"decode di un non-Dictionary restituisce {}")

	var oversize := PackedByteArray()
	oversize.resize(Protocol.MAX_PACKET_BYTES + 1)
	check(Protocol.decode(oversize).is_empty(),
		"decode di un pacchetto oltre MAX_PACKET_BYTES restituisce {}")

	var round_trip := Protocol.decode(Protocol.encode({"t": "X", "n": 7, "cell": Vector2i(3, 4)}))
	check(round_trip.get("t") == "X", "encode->decode conserva il tipo")
	check(round_trip.get("n") == 7, "encode->decode conserva i campi scalari")
	check(round_trip.get("cell") == Vector2i(3, 4), "encode->decode conserva Vector2i")

	check(Protocol.PROTOCOL_VERSION == 4, "PROTOCOL_VERSION == 4")

	# La cronologia passa dal master come tutto il resto: il client non parla
	# mai HTTP col database.
	var hist := Protocol.decode(Protocol.encode(Protocol.make(Protocol.HISTORY_REQUEST, {
		"session_token": "t", "limit": 20})))
	check(Protocol.message_type(hist) == Protocol.HISTORY_REQUEST
		and int(hist.get("limit", 0)) == 20, "HISTORY_REQUEST sopravvive alla codifica")
	var data := Protocol.decode(Protocol.encode(Protocol.make(Protocol.HISTORY_DATA, {
		"matches": [{"match_id": "m", "placement": 2}]})))
	check(Protocol.message_type(data) == Protocol.HISTORY_DATA
		and data.get("matches", []).size() == 1, "HISTORY_DATA sopravvive alla codifica")


func _test_match_token() -> void:
	section("Match token — HMAC")

	var tok := MatchToken.mint("m1", "uid-a", 1000, 120)
	var claims := MatchToken.verify(tok, 1030)
	check(claims.get("match_id") == "m1" and claims.get("uid") == "uid-a",
		"un token valido verifica e restituisce match_id/uid")
	check(MatchToken.verify(tok, 2000).is_empty(),
		"un token scaduto viene rifiutato")
	check(MatchToken.verify(tok + "x", 1030).is_empty(),
		"un token con firma alterata viene rifiutato")
	check(MatchToken.verify("garbage", 1030).is_empty(),
		"un token malformato viene rifiutato")


func _test_session_token() -> void:
	section("Session token — HMAC (login self-hosted)")

	var tok := SessionToken.mint("u1", "Tizio|Caio", 1000, 100)
	var claims := SessionToken.verify(tok, 1050)
	check(claims.get("sub") == "u1", "un token valido restituisce sub")
	check(claims.get("name") == "Tizio|Caio", "l'username sopravvive al round-trip anche con '|'")
	check(SessionToken.verify(tok, 2000).is_empty(), "un token scaduto viene rifiutato")

	var bytes := tok.to_utf8_buffer()
	bytes[bytes.size() - 3] ^= 0x01
	check(SessionToken.verify(bytes.get_string_from_utf8(), 1050).is_empty(),
		"un token con un byte alterato viene rifiutato")
	check(SessionToken.verify("garbage", 1050).is_empty(), "un token malformato viene rifiutato")

	# SessionVerifier è l'adattatore d'istanza iniettato in Matchmaker.
	var v := SessionVerifier.new()
	check(v.verify(SessionToken.mint("u2", "Sempronio")).get("sub") == "u2",
		"SessionVerifier.verify() delega a SessionToken")


func _test_hello_rejects() -> void:
	section("HELLO — rifiuti")

	var fv := FakeVerifier.new()
	fv.add("good", "uid-x")
	var mm := Matchmaker.new(fv)

	mm.handle_connect(1)
	mm.handle_packet(1, Protocol.encode({"t": "HELLO", "protocol_version": 99, "access_token": "good"}))
	var r1 := _first_to(mm.pending_outbox(), 1)
	check(r1.get("t") == Protocol.REJECTED and r1.get("reason") == "version",
		"protocol_version errata -> REJECTED{version}")

	mm.handle_connect(2)
	mm.handle_packet(2, Protocol.encode({"t": "HELLO", "protocol_version": Protocol.PROTOCOL_VERSION, "access_token": "bogus"}))
	var r2 := _first_to(mm.pending_outbox(), 2)
	check(r2.get("t") == Protocol.REJECTED and r2.get("reason") == "auth",
		"JWT non valido -> REJECTED{auth}")

	mm.handle_connect(3)
	mm.handle_packet(3, Protocol.encode({"t": "HELLO", "protocol_version": Protocol.PROTOCOL_VERSION, "access_token": "good"}))
	var w := _first_to(mm.pending_outbox(), 3)
	check(w.get("t") == Protocol.WELCOME and w.get("user_id") == "uid-x",
		"HELLO valido -> WELCOME con user_id")


func _test_matchmaking_seal() -> void:
	section("Matchmaking — sigillo a 30 s con 3 umani")

	var fv := FakeVerifier.new()
	fv.add("tok-a", "uid-a")
	fv.add("tok-b", "uid-b")
	fv.add("tok-c", "uid-c")

	var mm := Matchmaker.new(fv)
	mm.force_seed = 123456789
	var spawns: Array = []
	mm.spawn_requested.connect(func(p: Dictionary) -> void: spawns.append(p))

	for pair in [[10, "tok-a"], [11, "tok-b"], [12, "tok-c"]]:
		mm.handle_connect(pair[0])
		mm.handle_packet(pair[0], Protocol.encode({
			"t": "HELLO", "protocol_version": Protocol.PROTOCOL_VERSION, "access_token": pair[1]}))
		mm.handle_packet(pair[0], Protocol.encode({
			"t": "QUEUE_JOIN", "hero_id": "vercingetorige"}))

	check(mm.size() == 3, "3 giocatori in coda", str(mm.size()))
	check(not mm.is_sealed(), "la lobby non e' ancora sigillata")

	# QUEUE_UPDATE mandato durante l'attesa.
	mm.pending_outbox()  # scarta WELCOME + primi QUEUE_UPDATE
	mm.tick(1.0)
	var mid_updates := _all_of_type(mm.pending_outbox(), Protocol.QUEUE_UPDATE)
	check(mid_updates.size() >= 1 and int(mid_updates[0].get("players", 0)) == 3,
		"QUEUE_UPDATE in broadcast riporta 3 giocatori")

	# Oltre i 30 s.
	mm.tick(30.0)
	check(mm.is_sealed(), "allo scadere dei 30 s la lobby si sigilla")

	var seal := mm.last_seal()
	var humans := 0
	var bots := 0
	for s in seal.slots:
		if s.kind == "human":
			humans += 1
		else:
			bots += 1
	check(humans == 3 and bots == 5, "match sigillato con 3 umani + 5 bot",
		"%d umani, %d bot" % [humans, bots])
	check(seal.slots.size() == 8, "8 slot totali")
	check(seal.ranked == true, "3 umani (>= 2) -> ranked = true")

	check(spawns.size() == 1, "un solo SPAWN_MATCH emesso", str(spawns.size()))
	check(int(spawns[0].get("seed", 0)) == 123456789, "SPAWN_MATCH porta il seed esplicito")
	check(spawns[0].get("match_id") == seal.match_id, "SPAWN_MATCH e last_seal condividono match_id")

	# MATCH_ASSIGNED a tutti e 3, stesso match_id e stesso seed.
	var assigned := _by_peer(mm.pending_outbox(), Protocol.MATCH_ASSIGNED)
	check(assigned.size() == 3, "tutti e 3 i client ricevono MATCH_ASSIGNED", str(assigned.size()))
	var ids := {}
	var seeds := {}
	for pid in assigned:
		ids[assigned[pid].get("match_id")] = true
		seeds[int(assigned[pid].get("seed", -1))] = true
		var mt: Dictionary = MatchToken.verify(String(assigned[pid].get("match_token", "")))
		check(not mt.is_empty(), "il match_token del client %d e' valido" % pid)
	check(ids.size() == 1 and ids.has(seal.match_id),
		"i 3 MATCH_ASSIGNED hanno lo STESSO match_id")
	check(seeds.size() == 1 and seeds.has(123456789),
		"i 3 MATCH_ASSIGNED hanno lo STESSO seed")

	# Caso limite: 1 umano + 7 bot -> ranked = false.
	var mm2 := Matchmaker.new(fv)
	mm2.handle_connect(20)
	mm2.handle_packet(20, Protocol.encode({"t": "HELLO", "protocol_version": Protocol.PROTOCOL_VERSION, "access_token": "tok-a"}))
	mm2.handle_packet(20, Protocol.encode({"t": "QUEUE_JOIN", "hero_id": "cesare"}))
	mm2.tick(31.0)
	check(mm2.last_seal().ranked == false, "1 umano + 7 bot -> ranked = false")

	# 8 giocatori sigillano subito, senza aspettare il timer.
	var mm3 := Matchmaker.new(FakeVerifier.new())
	var fv3: FakeVerifier = mm3.verifier
	for i in 8:
		var t := "t%d" % i
		fv3.add(t, "uid%d" % i)
		mm3.handle_connect(100 + i)
		mm3.handle_packet(100 + i, Protocol.encode({"t": "HELLO", "protocol_version": Protocol.PROTOCOL_VERSION, "access_token": t}))
		mm3.handle_packet(100 + i, Protocol.encode({"t": "QUEUE_JOIN", "hero_id": ""}))
	check(mm3.is_sealed(), "8 giocatori sigillano la lobby immediatamente")
	check(mm3.last_seal().ranked == true, "8 umani -> ranked = true")


## A1 — dopo il sigillo il master apre una nuova lobby. Qui si simula il
## comportamento del master usando due Matchmaker indipendenti.
func _test_matchmaking_relobby() -> void:
	section("Matchmaking — nuova lobby dopo il sigillo (A1)")

	var fv := FakeVerifier.new()
	fv.add("x", "uid-x")
	var mm := Matchmaker.new(fv)
	var seals := [0]  # GDScript cattura le locali per valore: si usa un array
	mm.sealed.connect(func() -> void: seals[0] += 1)

	mm.handle_connect(1)
	mm.handle_packet(1, Protocol.encode({"t": "HELLO", "protocol_version": Protocol.PROTOCOL_VERSION, "access_token": "x"}))
	mm.handle_packet(1, Protocol.encode({"t": "QUEUE_JOIN", "hero_id": "cesare"}))
	mm.tick(31.0)
	check(mm.is_sealed(), "prima lobby sigillata")
	check(seals[0] == 1, "il segnale sealed è emesso una volta", str(seals[0]))

	# Il master, ricevuto sealed, crea una seconda Matchmaker per i nuovi arrivi.
	var mm2 := Matchmaker.new(fv)
	fv.add("y", "uid-y")
	mm2.handle_connect(2)
	mm2.handle_packet(2, Protocol.encode({"t": "HELLO", "protocol_version": Protocol.PROTOCOL_VERSION, "access_token": "y"}))
	mm2.handle_packet(2, Protocol.encode({"t": "QUEUE_JOIN", "hero_id": "cesare"}))
	check(mm2.size() == 1 and not mm2.is_sealed(), "la seconda lobby accetta il nuovo peer")
	mm2.tick(31.0)
	check(mm2.is_sealed(), "anche la seconda lobby si sigilla per conto suo")
	check(mm2.last_seal().match_id != mm.last_seal().match_id, "le due partite hanno match_id diversi")


## A2 — SPAWN_MATCH firmato: il worker lo rifiuta se la firma non torna.
func _test_spawn_signature() -> void:
	section("SPAWN_MATCH — firma HMAC (A2)")

	var fv := FakeVerifier.new()
	fv.add("t", "uid-a")
	var mm := Matchmaker.new(fv)
	mm.force_seed = 42
	var spawns: Array = []
	mm.spawn_requested.connect(func(p: Dictionary) -> void: spawns.append(p))
	mm.handle_connect(1)
	mm.handle_packet(1, Protocol.encode({"t": "HELLO", "protocol_version": Protocol.PROTOCOL_VERSION, "access_token": "t"}))
	mm.handle_packet(1, Protocol.encode({"t": "QUEUE_JOIN", "hero_id": "cesare"}))
	mm.tick(31.0)

	check(spawns.size() == 1, "SPAWN_MATCH emesso")
	var payload: Dictionary = spawns[0]
	check(payload.has("spawn_sig") and payload.spawn_sig != "", "SPAWN_MATCH porta una spawn_sig")
	check(MatchToken.verify_control(payload, payload.spawn_sig),
		"la firma del master verifica")

	var tampered := payload.duplicate(true)
	tampered.seed = 999
	check(not MatchToken.verify_control(tampered, payload.spawn_sig),
		"un SPAWN_MATCH manomesso (seed) non verifica")

	tampered = payload.duplicate(true)
	tampered.slots[0]["uid"] = "intruso"
	check(not MatchToken.verify_control(tampered, payload.spawn_sig),
		"un SPAWN_MATCH manomesso (uid di uno slot) non verifica")

	check(not MatchToken.verify_control(payload, ""),
		"firma vuota -> rifiutata")


## A3 — l'hero dichiarato dal client è sanificato contro data/heroes.json.
func _test_hero_revalidation() -> void:
	section("QUEUE_JOIN — rivalidazione dell'hero (A3)")

	var fv := FakeVerifier.new()
	fv.add("t", "uid-a")
	var mm := Matchmaker.new(fv)
	var reviews: Array = []
	mm.hero_review.connect(func(uid: String, hero_id: String) -> void:
		reviews.append([uid, hero_id]))

	mm.handle_connect(1)
	mm.handle_packet(1, Protocol.encode({"t": "HELLO", "protocol_version": Protocol.PROTOCOL_VERSION, "access_token": "t"}))
	mm.handle_packet(1, Protocol.encode({"t": "QUEUE_JOIN", "hero_id": "eroe_inventato_dal_client"}))

	var entry: Dictionary = mm.entries()[0]
	check(entry.hero_id == GameData.DEFAULT_HERO_ID,
		"un hero_id sconosciuto viene sostituito col default", entry.hero_id)
	check(reviews.size() == 1 and reviews[0][0] == "uid-a" and reviews[0][1] == GameData.DEFAULT_HERO_ID,
		"hero_review emesso con l'id già sanificato")

	# override_hero (chiamato dal master dopo il controllo asincrono su owned_civs).
	fv.add("t2", "uid-b")
	mm.handle_connect(2)
	mm.handle_packet(2, Protocol.encode({"t": "HELLO", "protocol_version": Protocol.PROTOCOL_VERSION, "access_token": "t2"}))
	mm.handle_packet(2, Protocol.encode({"t": "QUEUE_JOIN", "hero_id": "vercingetorige"}))
	mm.override_hero("uid-b", "cesare")
	var entry_b := {}
	for e in mm.entries():
		if e.uid == "uid-b":
			entry_b = e
	check(entry_b.get("hero_id") == "cesare", "override_hero sostituisce l'hero in coda")


# --------------------------------------------------------------------------
# M5 — MatchRunner: il match autoritativo
# --------------------------------------------------------------------------

const HUMAN_UID := "uid-h"


func _spawn_payload(match_id: String, seed_value: int) -> Dictionary:
	var slots: Array = []
	for i in 8:
		if i == 0:
			slots.append({"index": 0, "kind": "human", "uid": HUMAN_UID,
				"hero_id": "cesare", "username": "Ospite"})
		else:
			slots.append({"index": i, "kind": "bot", "uid": "",
				"hero_id": "", "username": "Bot %d" % i})
	return Protocol.make(Protocol.SPAWN_MATCH, {
		"match_id": match_id, "seed": seed_value, "slots": slots,
		"ranked": false, "worker_path": "/ws/w1"})


func _join(runner: MatchRunner, peer: int, match_id: String) -> void:
	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.JOIN, {
		"match_id": match_id,
		"match_token": MatchToken.mint(match_id, HUMAN_UID),
	})))


func _drain(runner: MatchRunner, sink: Array) -> void:
	for item in runner.pending_outbox():
		sink.append(item.msg)


func _has_type(msgs: Array, t: String) -> Dictionary:
	for m in msgs:
		if Protocol.message_type(m) == t:
			return m
	return {}


## Un turno di preparazione minimo per il posto umano: compra la prima casella
## del negozio e schiera tutto quello che ha in panchina. Senza, il posto umano
## arriva a fine partita senza aver mai messo un'unita' in campo e non produce
## ne' telemetria ne' una partita realistica.
func _play_preparation(runner: MatchRunner, peer: int) -> void:
	if runner.phase() != MatchRunner.Phase.PREPARATION:
		return
	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.CMD_BUY, {"slot": 0})))
	var player: Player = runner.state().players[0]
	for inst in player.bench_units():
		if not player.can_deploy_more():
			return
		var cell := _free_cell(player)
		if cell.x < 0:
			return
		runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.CMD_MOVE_BOARD, {
			"uid": inst.uid, "cell": cell})))


func _free_cell(player: Player) -> Vector2i:
	var board: Dictionary = GameData.balance()["match"]
	for y in int(board["board_rows"]):
		for x in int(board["board_columns"]):
			if player.unit_at_cell(Vector2i(x, y)) == null:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _test_runner_full_match() -> void:
	section("MatchRunner — match completo 1 umano + 7 bot")

	var runner := MatchRunner.new(_spawn_payload("mr1", 424242))
	var peer := 1
	var seen: Array = []
	_join(runner, peer, "mr1")
	_drain(runner, seen)

	var finished := {}
	var guard := 0
	while not runner.is_finished() and guard < 400:
		_play_preparation(runner, peer)
		runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.READY, {})))
		runner.tick(60.0)   # scade la preparazione -> resolve
		runner.tick(120.0)  # scade il ritmo del combattimento -> round dopo / fine
		_drain(runner, seen)
		var mf := _has_type(seen, Protocol.MATCH_FINISHED)
		if not mf.is_empty():
			finished = mf
		guard += 1

	check(runner.is_finished(), "il match termina entro il guard", "guard=%d" % guard)
	check(not finished.is_empty(), "il client riceve MATCH_FINISHED")

	var standings: Array = finished.get("standings", [])
	check(standings.size() == 8, "8 posizioni in classifica", str(standings.size()))
	var places := {}
	for s in standings:
		places[int(s.get("placement", 0))] = true
	check(places.size() == 8, "nessun piazzamento duplicato", str(places.keys()))
	var ok_range := true
	for pl in places:
		if pl < 1 or pl > 8:
			ok_range = false
	check(ok_range, "i piazzamenti sono 1..8")

	var human := {}
	for s in standings:
		if s.get("uid") == HUMAN_UID:
			human = s
	check(not human.is_empty() and int(human.get("placement", 0)) >= 1,
		"il posto umano ha un piazzamento coerente")

	# Telemetria di bilanciamento: e' quello che finisce in match_units nella
	# stessa transazione del risultato (db/migrations/0004_match_units.sql).
	var rows := runner.telemetry_rows()
	check(not rows.is_empty(), "il match finito produce righe di telemetria", str(rows.size()))
	var only_human := true
	var coherent := true
	for row in rows:
		if String(row.get("profile_id", "")) != HUMAN_UID:
			only_human = false
		if int(row.get("rounds_fielded", 0)) <= 0 or int(row.get("placement", 0)) <= 0:
			coherent = false
	check(only_human, "solo i posti umani finiscono nel database")
	check(coherent, "ogni riga ha round schierati e piazzamento")


## A5 — dopo un round, un client può chiedere lo schieramento di un altro
## giocatore (il worker manda solo il tuo log di combattimento di default).
func _test_runner_spectate() -> void:
	section("MatchRunner — SPECTATE_REQUEST (A5)")

	var runner := MatchRunner.new(_spawn_payload("mrs", 20260828))
	var peer := 3
	_join(runner, peer, "mrs")
	var junk: Array = []
	_drain(runner, junk)

	# Chiude la preparazione: si risolve il round, _last_results si popola.
	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.READY, {})))
	runner.tick(60.0)
	_drain(runner, junk)

	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.SPECTATE_REQUEST,
		{"player_index": 1})))
	var out: Array = []
	_drain(runner, out)
	var sd := _has_type(out, Protocol.SPECTATE_DATA)
	check(not sd.is_empty(), "arriva un SPECTATE_DATA")
	check(int(sd.get("player_index", -1)) == 1, "SPECTATE_DATA è del giocatore chiesto")
	check(sd.has("team") and sd.has("opponent_hero_id"),
		"SPECTATE_DATA porta team e opponent_hero_id per la CombatView")
	var combat: Variant = sd.get("combat", {})
	var has_log := (combat is Dictionary and not (combat as Dictionary).is_empty()) \
		or (combat is PackedByteArray and not (combat as PackedByteArray).is_empty())
	check(has_log, "SPECTATE_DATA contiene il log di combattimento")

	# Un indice che non ha combattuto (fuori range) non genera risposta.
	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.SPECTATE_REQUEST,
		{"player_index": 99})))
	var out2: Array = []
	_drain(runner, out2)
	check(_has_type(out2, Protocol.SPECTATE_DATA).is_empty(),
		"nessun SPECTATE_DATA per un indice inesistente")


## Con i vivi in numero dispari lo spaiato affronta il fantasma di un eliminato:
## quel replay è chiedibile da entrambi gli endpoint, dal proprio lato dell'arena.
func _test_runner_spectate_ghost() -> void:
	section("MatchRunner — SPECTATE_REQUEST su un matchup fantasma")

	var runner := MatchRunner.new(_spawn_payload("mrsg", 424242))
	var peer := 3
	_join(runner, peer, "mrsg")
	var junk: Array = []
	_drain(runner, junk)

	var state := runner.state()
	for i in [4, 5, 6]:
		var v: Player = state.players[i]
		v.move_to_board(v.grant_unit("legionarius"), Vector2i(0, 0))
		v.take_damage(v.hp, state.next_damage_stamp())
	for p in state.alive_players():
		if p.board_units().is_empty():
			p.move_to_board(p.grant_unit("legionarius"), Vector2i(0, 0))
	check(state.alive_players().size() == 5, "cinque vivi -> conta dispari")

	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.READY, {})))
	runner.tick(60.0)
	_drain(runner, junk)

	var ghost := {}
	for row in runner._public_results():
		if bool(row.get("ghost", false)) and int(row.get("opponent_index", -1)) >= 0:
			ghost = row
			break
	check(not ghost.is_empty(), "il round ha prodotto un matchup fantasma")
	var live_idx := int(ghost.get("player_index", -1))
	var dead_idx := int(ghost.get("opponent_index", -1))

	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.SPECTATE_REQUEST,
		{"player_index": live_idx})))
	var out_live: Array = []
	_drain(runner, out_live)
	var sd_live := _has_type(out_live, Protocol.SPECTATE_DATA)
	check(not sd_live.is_empty(), "SPECTATE_DATA per il lato vivo")

	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.SPECTATE_REQUEST,
		{"player_index": dead_idx})))
	var out_dead: Array = []
	_drain(runner, out_dead)
	var sd_dead := _has_type(out_dead, Protocol.SPECTATE_DATA)
	check(not sd_dead.is_empty(), "SPECTATE_DATA anche per il lato eliminato")
	check(not sd_live.is_empty() and not sd_dead.is_empty() \
		and int(sd_dead.get("team", -9)) == 1 - int(sd_live.get("team", -8)),
		"i due lati dell'arena sono opposti")

	var c: Variant = sd_dead.get("combat", {})
	var has_log := (c is Dictionary and not (c as Dictionary).is_empty()) \
		or (c is PackedByteArray and not (c as PackedByteArray).is_empty())
	check(has_log, "il log di combattimento è incluso")


func _test_runner_reject_out_of_phase() -> void:
	section("MatchRunner — comando fuori fase -> COMMAND_REJECTED")

	var runner := MatchRunner.new(_spawn_payload("mr2", 999))
	var peer := 7
	_join(runner, peer, "mr2")
	var junk: Array = []
	_drain(runner, junk)

	# Chiude la preparazione e passa a COMBAT (ritmo in corso, non ancora il round dopo).
	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.READY, {})))
	runner.tick(60.0)
	_drain(runner, junk)
	check(runner.phase() == MatchRunner.Phase.COMBAT, "il runner e' in COMBAT dopo il resolve")

	var gold_before: int = runner.state().players[0].gold
	var level_before: int = runner.state().players[0].level
	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.CMD_REROLL, {})))
	var out: Array = []
	_drain(runner, out)
	var rej := _has_type(out, Protocol.COMMAND_REJECTED)
	check(not rej.is_empty() and rej.get("reason") == "phase",
		"CMD in COMBAT -> COMMAND_REJECTED{phase}", str(rej))
	check(runner.state().players[0].gold == gold_before
		and runner.state().players[0].level == level_before,
		"lo stato non e' cambiato")


## Il pool e' condiviso: un posto eliminato che continua a comprare toglie copie
## a chi e' ancora in gioco. Il server lo rifiuta anche se il client insiste.
func _test_runner_reject_eliminated() -> void:
	section("MatchRunner — comando da un posto eliminato -> rifiutato")

	var runner := MatchRunner.new(_spawn_payload("mre", 4711))
	var peer := 5
	_join(runner, peer, "mre")
	var junk: Array = []
	_drain(runner, junk)

	var state := runner.state()
	var p: Player = state.players[0]
	p.gold = 99
	p.take_damage(p.hp, state.next_damage_stamp())
	check(not p.is_alive(), "il posto 0 e' eliminato")

	var pool_before := state.pool.snapshot()
	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.CMD_REROLL, {})))
	var out: Array = []
	_drain(runner, out)
	var rej := _has_type(out, Protocol.COMMAND_REJECTED)
	check(not rej.is_empty() and rej.get("reason") == "eliminated",
		"CMD da eliminato -> COMMAND_REJECTED{eliminated}", str(rej))
	check(p.gold == 99, "l'oro non e' stato speso", str(p.gold))
	check(state.pool.snapshot() == pool_before, "il pool condiviso non e' stato toccato")


## _on_spectate non aveva il gate d'identita' che _on_command ha sempre avuto.
func _test_runner_spectate_requires_join() -> void:
	section("MatchRunner — SPECTATE_REQUEST da un peer non entrato")

	var runner := MatchRunner.new(_spawn_payload("mrsj", 8080))
	var joined := 1
	_join(runner, joined, "mrsj")
	var junk: Array = []
	_drain(runner, junk)
	runner.handle_packet(joined, Protocol.encode(Protocol.make(Protocol.READY, {})))
	runner.tick(60.0)
	_drain(runner, junk)

	# Un peer che non ha mai mandato JOIN.
	runner.handle_packet(99, Protocol.encode(Protocol.make(Protocol.SPECTATE_REQUEST,
		{"player_index": 1})))
	var out: Array = []
	_drain(runner, out)
	check(_has_type(out, Protocol.SPECTATE_DATA).is_empty(),
		"nessun SPECTATE_DATA per un peer non entrato")
	var rej := _has_type(out, Protocol.COMMAND_REJECTED)
	check(not rej.is_empty() and rej.get("reason") == "not_joined",
		"e riceve COMMAND_REJECTED{not_joined}", str(rej))


## Un eliminato guarda soltanto, ma il suo PRONTO deve contare: se non contasse,
## chi e' fuori si guarderebbe ogni round a timer pieno.
func _test_runner_eliminated_counts_as_ready() -> void:
	section("MatchRunner — un eliminato non blocca il round e riceve gli aggiornamenti")

	var runner := MatchRunner.new(_spawn_payload("mrer", 2024))
	var peer := 4
	_join(runner, peer, "mrer")
	var junk: Array = []
	_drain(runner, junk)

	var state := runner.state()
	state.players[0].take_damage(state.players[0].hp, state.next_damage_stamp())
	check(not state.players[0].is_alive(), "l'unico umano e' eliminato")

	var round_before: int = state.round_index
	# Un eliminato non ha PRONTO: il round scorre sul timer, non si blocca.
	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.READY, {})))
	runner.tick(60.0)  # oltre i 45 s di preparazione
	runner.tick(120.0)
	var out: Array = []
	_drain(runner, out)
	check(not _has_type(out, Protocol.ROUND_STARTED).is_empty(),
		"l'eliminato riceve comunque ROUND_STARTED")
	check(not _has_type(out, Protocol.MATCH_STATE).is_empty(),
		"e lo snapshot per aggiornare la classifica")
	check(state.round_index != round_before or state.stage > 1, "il round e' avanzato")


func _test_runner_reject_wrong_index() -> void:
	section("MatchRunner — player_index non del peer -> rifiutato")

	var runner := MatchRunner.new(_spawn_payload("mr3", 555))
	var peer := 3
	_join(runner, peer, "mr3")
	var junk: Array = []
	_drain(runner, junk)

	var gold_before: int = runner.state().players[0].gold
	runner.handle_packet(peer, Protocol.encode(Protocol.make(Protocol.CMD_REROLL, {"player_index": 4})))
	var out: Array = []
	_drain(runner, out)
	var rej := _has_type(out, Protocol.COMMAND_REJECTED)
	check(not rej.is_empty() and rej.get("reason") == "identity",
		"player_index altrui -> COMMAND_REJECTED{identity}", str(rej))
	check(runner.state().players[0].gold == gold_before, "lo stato non e' cambiato")


func _test_runner_disconnect_reconnect() -> void:
	section("MatchRunner — disconnessione a meta' partita + riconnessione")

	var runner := MatchRunner.new(_spawn_payload("mr4", 31337))
	var peer_a := 10
	_join(runner, peer_a, "mr4")
	var junk: Array = []
	_drain(runner, junk)

	# Un paio di round giocati, senza arrivare alla fine.
	for i in 2:
		runner.handle_packet(peer_a, Protocol.encode(Protocol.make(Protocol.READY, {})))
		runner.tick(60.0)
		runner.tick(120.0)
		_drain(runner, junk)

	check(not runner.is_finished(), "la partita e' ancora in corso")

	# Il peer cade.
	runner.handle_disconnect(peer_a)
	check(runner.peer_for_seat(0) == -1, "il posto 0 non ha piu' un peer")
	check(not runner.state().players[0].eliminated,
		"la disconnessione NON elimina il giocatore")
	check(runner.seat_reserved(0), "il posto 0 resta prenotato")

	# Un round giocato dal BotBrain di rimpiazzo.
	runner.tick(60.0)
	runner.tick(120.0)
	_drain(runner, junk)
	check(not runner.state().players[0].eliminated,
		"il posto resta non eliminato mentre e' pilotato dal bot")

	# Riconnessione con lo stesso match_token.
	var peer_b := 11
	_join(runner, peer_b, "mr4")
	var out: Array = []
	_drain(runner, out)
	check(runner.peer_for_seat(0) == peer_b, "il nuovo peer riprende il posto 0")
	check(not _has_type(out, Protocol.MATCH_STATE).is_empty(),
		"alla riconnessione arriva un MATCH_STATE")


# --------------------------------------------------------------------------

## Primo messaggio dell'outbox indirizzato a `peer`.
func _first_to(outbox: Array, peer: int) -> Dictionary:
	for item in outbox:
		if peer in item.peers:
			return item.msg
	return {}


func _all_of_type(outbox: Array, t: String) -> Array:
	var out: Array = []
	for item in outbox:
		if Protocol.message_type(item.msg) == t:
			out.append(item.msg)
	return out


## {peer_id -> msg} per i messaggi del tipo dato (uno per peer).
func _by_peer(outbox: Array, t: String) -> Dictionary:
	var out: Dictionary = {}
	for item in outbox:
		if Protocol.message_type(item.msg) == t:
			for pid in item.peers:
				out[pid] = item.msg
	return out


func section(title: String) -> void:
	print("\n== %s ==" % title)


func check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % label)
	else:
		_failed += 1
		printerr("  FAIL %s%s" % [label, ("  -> " + detail) if detail != "" else ""])
