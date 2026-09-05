-- =============================================================================
-- unit_balance.sql — le query che si lanciano a mano quando si tocca il
-- bilanciamento. Nessuna schermata le legge: i numeri servono a chi bilancia.
--
--   psql "$DB_URL" -f db/unit_balance.sql
--
-- La sorgente è public.match_units (db/migrations/0004_match_units.sql): una
-- riga per (partita, giocatore, unità schierata), scritta dal server a fine
-- partita nella stessa transazione del risultato. Le partite locali contro il
-- computer NON sono qui: quelle stanno in user://telemetry.jsonl e si guardano
-- con `godot --headless --path . --script res://tools/unit_balance.gd`.
-- =============================================================================

\echo '--- quante partite ci sono sotto questi numeri ---'
select count(*)                                as righe,
       count(distinct match_id)                as partite,
       count(distinct profile_id)              as giocatori
from public.match_units;

\echo ''
\echo '--- unità: le piu deboli in alto (winrate di round) ---'
select * from public.unit_balance
order by round_win_rate asc nulls last;

\echo ''
\echo '--- unità: quanto vengono scelte ---'
select unit_id, picks, pick_rate, avg_rounds_fielded, avg_final_star
from public.unit_balance
order by picks desc;

\echo ''
\echo '--- solo partite classificate (la ladder vera) ---'
select u.unit_id,
       count(*)                                                  as picks,
       round(avg(u.rounds_fielded)::numeric, 2)                  as avg_rounds_fielded,
       round(100.0 * sum(u.rounds_won)
             / nullif(sum(u.rounds_won + u.rounds_lost), 0), 1)  as round_win_rate,
       round(avg(u.placement)::numeric, 2)                       as avg_placement
from public.match_units u
join public.match_history h on h.match_id = u.match_id
where h.ranked
group by u.unit_id
order by round_win_rate asc nulls last;

\echo ''
\echo '--- copertura: unità con troppo pochi dati per dire qualcosa ---'
select unit_id, picks, rounds_fielded
from public.unit_balance
where rounds_fielded < 30
order by rounds_fielded asc;
