-- =============================================================================
-- 0006_leaderboard.sql — classifica dei giocatori per mmr.
-- =============================================================================
--
-- Una sola lettura, due risposte: i primi N e la riga di chi chiede, così chi
-- sta fuori dai primi cento vede comunque dove si trova senza un secondo giro.
--
--   * Entra solo chi ha almeno una partita classificata: gli account appena
--     creati stanno tutti a 1000 e riempirebbero la lista di pari merito.
--   * `row_number` con spareggio deterministico (mmr, vittorie, meno partite,
--     nome): due richieste di fila danno lo stesso ordine, e una posizione
--     condivisa non farebbe capire a chi tocca il gradino successivo.
--   * Si espongono username e statistiche, mai id o email: la classifica la
--     vede chiunque abbia un account.
-- =============================================================================

create or replace function public.leaderboard(p_uid uuid, p_limit int)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with ranked as (
    select p.id, p.username, s.mmr, s.matches_played, s.wins, s.top4,
           row_number() over (
             order by s.mmr desc, s.wins desc, s.matches_played asc, p.username
           ) as position
    from public.player_stats s
    join public.profiles p on p.id = s.profile_id
    where s.matches_played > 0
  )
  select jsonb_build_object(
    'top', coalesce((
      select jsonb_agg(jsonb_build_object(
               'position',       r.position,
               'username',       r.username,
               'mmr',            r.mmr,
               'matches_played', r.matches_played,
               'wins',           r.wins,
               'top4',           r.top4,
               'is_me',          r.id = p_uid
             ) order by r.position)
      from ranked r
      where r.position <= greatest(1, least(coalesce(p_limit, 100), 100))
    ), '[]'::jsonb),
    'me', (
      select jsonb_build_object(
               'position',       r.position,
               'username',       r.username,
               'mmr',            r.mmr,
               'matches_played', r.matches_played,
               'wins',           r.wins,
               'top4',           r.top4,
               'is_me',          true
             )
      from ranked r
      where r.id = p_uid
    )
  );
$$;

revoke all on function public.leaderboard(uuid, int) from public;
grant execute on function public.leaderboard(uuid, int) to autochess_app;
