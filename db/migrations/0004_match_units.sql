-- =============================================================================
-- 0004_match_units.sql — cronologia consultabile + telemetria per unità.
-- =============================================================================
--
-- Prima di questa migrazione una partita lasciava una riga in match_history con
-- solo {profile_id, placement, hp, hero_id, top4, won}: nessuna squadra, nessun
-- round, e nessun modo per il client di rileggerla. Qui si aggiunge:
--
--   1. `match_units` — una riga per (partita, giocatore, unità schierata):
--      quante volte l'ho messa in campo, quanti round ha vinto, a che stella è
--      finita, se era ancora schierata alla fine. Aggregato per partita, non
--      per round: bastano ~8 righe per giocatore invece di migliaia, e le
--      domande di bilanciamento ("winrate", "round medi di impiego", "quanto
--      viene scelta") si rispondono lo stesso.
--
--   2. `record_match_result(..., p_units)` — le scrive nella STESSA transazione
--      del resto (stessa ragione per cui la funzione esiste: PostgREST non dà
--      transazioni multi-tabella). Serve un DROP perché cambia la firma, come
--      già in 0002.
--
--   3. `match_history.results` arricchito con `mmr_delta`/`mmr_after`: l'mmr era
--      calcolato ma non conservato, e la cronologia deve poterlo mostrare.
--
--   4. `player_match_history(profile, limit)` — la lettura per il client, che
--      arriva sempre passando dal master (net/protocol.gd HISTORY_REQUEST).
--      Una RPC e non un filtro PostgREST su jsonb: match_history contiene le
--      righe di tutti, e qui il filtro sul profilo è dentro la funzione.
--
--   5. `unit_balance` — la vista che si interroga a mano per bilanciare.
--
-- Come match_history, `match_units` non ha FK verso profiles e non viene
-- ripulita da delete_account: sono dati di partite già giocate, che restano
-- validi per il bilanciamento anche se l'account sparisce (stessa scelta
-- documentata in 0001_initial.sql).
-- =============================================================================

create table if not exists public.match_units (
  id             bigserial primary key,
  match_id       text not null references public.match_history(match_id) on delete cascade,
  profile_id     uuid not null,
  unit_id        text not null,
  final_star     int  not null default 1,
  fielded_end    bool not null default false,
  rounds_fielded int  not null default 0,
  rounds_won     int  not null default 0,
  rounds_lost    int  not null default 0,
  rounds_drawn   int  not null default 0,
  placement      int  not null default 0,
  constraint match_units_unique unique (match_id, profile_id, unit_id)
);

create index if not exists match_units_unit_idx    on public.match_units (unit_id);
create index if not exists match_units_profile_idx on public.match_units (profile_id);


-- -----------------------------------------------------------------------------
-- record_match_result — ora scrive anche match_units e conserva l'mmr.
-- -----------------------------------------------------------------------------

drop function if exists public.record_match_result(text, bigint, boolean, jsonb);
drop function if exists public.record_match_result(text, bigint, boolean, jsonb, jsonb);

create function public.record_match_result(
  p_match_id text,
  p_seed     bigint,
  p_ranked   boolean,
  p_results  jsonb,
  p_units    jsonb default '[]'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r             jsonb;
  v_entry       jsonb;
  v_profile     uuid;
  v_placement   int;
  v_k           constant int := 24;
  v_mid         constant numeric := 4.5;
  v_spread      constant numeric := 3.5;   -- (8 - 1) / 2
  v_delta       int;
  v_row         public.player_stats;
  v_updates     jsonb := '[]'::jsonb;
  v_results_out jsonb := '[]'::jsonb;
begin
  insert into public.match_history (match_id, seed, ranked, ended_at, results)
  values (p_match_id, p_seed, p_ranked, now(), coalesce(p_results, '[]'::jsonb))
  on conflict (match_id) do update
    set seed = excluded.seed, ranked = excluded.ranked,
        ended_at = excluded.ended_at, results = excluded.results;

  -- Telemetria: scritta anche per le lobby non-ranked. Un match con dei bot
  -- non muove l'mmr ma le unità in campo erano vere, e servono al bilanciamento.
  insert into public.match_units (match_id, profile_id, unit_id, final_star, fielded_end,
                                  rounds_fielded, rounds_won, rounds_lost, rounds_drawn, placement)
  select p_match_id,
         (u->>'profile_id')::uuid,
         u->>'unit_id',
         coalesce((u->>'final_star')::int, 1),
         coalesce((u->>'fielded_end')::boolean, false),
         coalesce((u->>'rounds_fielded')::int, 0),
         coalesce((u->>'rounds_won')::int, 0),
         coalesce((u->>'rounds_lost')::int, 0),
         coalesce((u->>'rounds_drawn')::int, 0),
         coalesce((u->>'placement')::int, 0)
  from jsonb_array_elements(coalesce(p_units, '[]'::jsonb)) u
  -- Il guardia-uuid evita che una riga malformata faccia fallire l'INTERA
  -- transazione, mmr compreso: si perde quella riga di telemetria, non la partita.
  where u->>'unit_id' is not null
    and u->>'profile_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  on conflict on constraint match_units_unique do nothing;

  -- lobby non-ranked (es. 1 umano + 7 bot): registrate per cronologia ma non
  -- muovono i contatori competitivi né l'mmr.
  if not coalesce(p_ranked, false) then
    return v_updates;
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    v_entry := r;
    v_profile := null;
    begin
      v_profile := (r->>'profile_id')::uuid;
    exception when others then
      v_profile := null;  -- profile_id assente / malformato: nessun aggiornamento
    end;

    if v_profile is not null then
      v_placement := coalesce((r->>'placement')::int, 8);
      v_delta := round(v_k * (v_mid - v_placement) / v_spread)::int;

      update public.player_stats set
        matches_played = matches_played + 1,
        wins       = wins + case when coalesce((r->>'won')::boolean,  false) then 1 else 0 end,
        top4       = top4 + case when coalesce((r->>'top4')::boolean, false) then 1 else 0 end,
        mmr        = greatest(0, mmr + v_delta),
        updated_at = now()
      where profile_id = v_profile
      returning * into v_row;

      -- profile_id valido ma senza player_stats (non dovrebbe accadere: la riga
      -- si crea insieme al profilo in upsert_google_account) -> salta, nessun
      -- aggiornamento da riportare al client.
      if found then
        v_updates := v_updates || jsonb_build_array(jsonb_build_object(
          'profile_id', v_row.profile_id,
          'mmr', v_row.mmr,
          'delta', v_delta,
          'matches_played', v_row.matches_played,
          'wins', v_row.wins,
          'top4', v_row.top4));
        v_entry := v_entry || jsonb_build_object('mmr_delta', v_delta, 'mmr_after', v_row.mmr);
      end if;
    end if;

    v_results_out := v_results_out || jsonb_build_array(v_entry);
  end loop;

  -- Riscrive results con l'mmr dentro: la cronologia mostra "+24" senza dover
  -- ricalcolare nulla lato client.
  update public.match_history set results = v_results_out where match_id = p_match_id;

  return v_updates;
end $$;


-- -----------------------------------------------------------------------------
-- player_match_history — le ultime partite di UN profilo, e solo le sue.
-- -----------------------------------------------------------------------------

create or replace function public.player_match_history(
  p_profile_id uuid,
  p_limit      int default 20
) returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(m) order by m.ended_at desc), '[]'::jsonb)
  from (
    select
      h.match_id,
      h.ended_at,
      h.ranked,
      h.seed,
      coalesce((e.entry->>'placement')::int, 0) as placement,
      coalesce(e.entry->>'hero_id', '')         as hero_id,
      coalesce((e.entry->>'hp')::int, 0)        as hp,
      coalesce((e.entry->>'mmr_delta')::int, 0) as mmr_delta,
      coalesce((e.entry->>'mmr_after')::int, 0) as mmr_after,
      jsonb_array_length(h.results)             as humans,
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'unit_id', mu.unit_id,
                 'final_star', mu.final_star,
                 'rounds_fielded', mu.rounds_fielded)
               order by mu.rounds_fielded desc, mu.unit_id)
        from public.match_units mu
        where mu.match_id = h.match_id
          and mu.profile_id = p_profile_id
          and mu.fielded_end
      ), '[]'::jsonb) as units
    from public.match_history h
    cross join lateral (
      select el as entry
      from jsonb_array_elements(h.results) el
      where el->>'profile_id' = p_profile_id::text
      limit 1
    ) e
    order by h.ended_at desc
    limit least(coalesce(p_limit, 20), 50)
  ) m;
$$;


-- -----------------------------------------------------------------------------
-- unit_balance — la vista da guardare quando si tocca data/units.json.
-- Nessuna UI la legge: è per chi bilancia (vedi db/unit_balance.sql).
-- -----------------------------------------------------------------------------

create or replace view public.unit_balance as
select
  u.unit_id,
  count(*)                                                   as picks,
  round(100.0 * count(*)
        / nullif((select count(distinct (match_id, profile_id))
                  from public.match_units), 0), 1)           as pick_rate,
  round(avg(u.final_star)::numeric, 2)                       as avg_final_star,
  round(avg(u.rounds_fielded)::numeric, 2)                   as avg_rounds_fielded,
  sum(u.rounds_fielded)                                      as rounds_fielded,
  round(100.0 * sum(u.rounds_won)
        / nullif(sum(u.rounds_won + u.rounds_lost), 0), 1)   as round_win_rate,
  round(avg(u.placement)::numeric, 2)                        as avg_placement,
  round(100.0 * count(*) filter (where u.placement = 1)
        / nullif(count(*), 0), 1)                            as win_rate,
  round(100.0 * count(*) filter (where u.placement between 1 and 4)
        / nullif(count(*), 0), 1)                            as top4_rate
from public.match_units u
group by u.unit_id;


-- -----------------------------------------------------------------------------
-- Grant (ruolo a privilegio minimo, come in 0001/0002)
-- -----------------------------------------------------------------------------

revoke all on function public.record_match_result(text, bigint, boolean, jsonb, jsonb) from public;
revoke all on function public.player_match_history(uuid, int) from public;

grant select on public.match_units, public.unit_balance to autochess_app;
grant execute on function public.record_match_result(text, bigint, boolean, jsonb, jsonb) to autochess_app;
grant execute on function public.player_match_history(uuid, int) to autochess_app;
