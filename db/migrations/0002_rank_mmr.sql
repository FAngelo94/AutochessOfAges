-- =============================================================================
-- 0002_rank_mmr.sql — l'mmr comincia davvero a muoversi.
-- =============================================================================
--
-- record_match_result già aggiornava matches_played/wins/top4 ma lasciava mmr
-- fermo al suo default (1000): la colonna esisteva, la ladder no. Questa
-- migrazione:
--   1. aggiorna l'mmr a piazzamento dentro la stessa transazione del resto;
--   2. fa tornare la funzione un jsonb con {profile_id, mmr, delta,
--      matches_played, wins, top4} per ogni umano toccato, così il worker può
--      spedire un RANK_UPDATE al client giusto senza una query separata
--      (server/stats_writer.gd, server/match_runner.gd).
--
-- Formula (partita a 8, piazzamento 1..8, centro alla posizione 4.5):
--   delta = round(K * (4.5 - placement) / 3.5)
-- Con K = 24: 1° = +24, 8° = -24, 4°/5° quasi zero. Costanti tenute qui invece
-- che in data/balance.json perché la formula gira solo lato server, mai letta
-- dal client (lo stesso principio di SEAL_SECONDS in server/matchmaker.gd — un
-- numero che riguarda solo la simulazione server-side resta lì dove si usa).
-- I nomi dei gradi mostrati in UI restano in data/balance.json["ranks"]
-- (GameData.rank_for_mmr) — qui c'è solo il numero.
--
-- Serve un DROP: si cambia il tipo di ritorno (void -> jsonb) e CREATE OR
-- REPLACE non lo permette.
-- =============================================================================

drop function if exists public.record_match_result(text, bigint, boolean, jsonb);

create function public.record_match_result(
  p_match_id text,
  p_seed     bigint,
  p_ranked   boolean,
  p_results  jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r           jsonb;
  v_profile   uuid;
  v_placement int;
  v_k         constant int := 24;
  v_mid       constant numeric := 4.5;
  v_spread    constant numeric := 3.5;   -- (8 - 1) / 2
  v_delta     int;
  v_row       public.player_stats;
  v_updates   jsonb := '[]'::jsonb;
begin
  insert into public.match_history (match_id, seed, ranked, ended_at, results)
  values (p_match_id, p_seed, p_ranked, now(), coalesce(p_results, '[]'::jsonb))
  on conflict (match_id) do update
    set seed = excluded.seed, ranked = excluded.ranked,
        ended_at = excluded.ended_at, results = excluded.results;

  -- lobby non-ranked (es. 1 umano + 7 bot): registrate per cronologia ma non
  -- muovono i contatori competitivi né l'mmr.
  if not coalesce(p_ranked, false) then
    return v_updates;
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    begin
      v_profile := (r->>'profile_id')::uuid;
    exception when others then
      continue;  -- profile_id assente / malformato: salta la riga
    end;
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
    end if;
  end loop;

  return v_updates;
end $$;

grant execute on function public.record_match_result(text, bigint, boolean, jsonb) to autochess_app;
