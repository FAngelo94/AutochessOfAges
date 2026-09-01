-- =============================================================================
-- 0001_initial.sql  —  Autochess Of Ages, schema self-hosted (Postgres 16)
-- =============================================================================
--
-- MODELLO DI SICUREZZA — leggere prima di cambiare qualsiasi cosa.
--
-- Nessun client raggiunge questo database. PostgREST ascolta su 127.0.0.1:3000 e
-- i soli chiamanti sono il master e il worker sulla stessa macchina (vedi
-- deploy/postgrest.conf, SETUP_DB.md). Non c'e' Row Level Security: non c'e' una
-- chiave pubblica in circolazione da contenere. La protezione e' l'isolamento di
-- rete + il ruolo `autochess_app` a privilegio minimo definito in fondo.
--
-- Se un domani il client tornasse a parlare HTTP col database, la RLS va RIMESSA
-- PRIMA, non dopo.
--
-- L'identita' e' Google: `profiles.google_sub` = claim "sub" dell'id_token. Il
-- primo login e la rotazione dei refresh token passano dalle funzioni qui sotto,
-- invocate dal master (server/account_service.gd).
-- =============================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid()

-- -----------------------------------------------------------------------------
-- Tabelle
-- -----------------------------------------------------------------------------

create table public.profiles (
  id               uuid primary key default gen_random_uuid(),
  google_sub       text unique not null,          -- claim "sub" dell'id_token Google
  email            text,
  username         text unique not null,
  favourite_origin text not null default '',
  favourite_hero   text not null default '',
  created_at       timestamptz not null default now()
);

create table public.player_stats (
  profile_id     uuid primary key references public.profiles(id) on delete cascade,
  matches_played int not null default 0,
  wins           int not null default 0,
  top4           int not null default 0,
  mmr            int not null default 1000,
  updated_at     timestamptz not null default now()
);

create table public.owned_civs (
  profile_id  uuid references public.profiles(id) on delete cascade,
  civ_id      text not null,
  source      text not null,                      -- 'default' | 'purchase' | 'promo'
  acquired_at timestamptz not null default now(),
  primary key (profile_id, civ_id)
);

create table public.match_history (
  id         uuid primary key default gen_random_uuid(),
  match_id   text unique,                          -- assegnato dal master; unique per scritture idempotenti
  seed       bigint not null,
  ranked     boolean not null default true,
  started_at timestamptz not null default now(),
  ended_at   timestamptz,
  results    jsonb not null default '[]'::jsonb    -- [{profile_id, placement, hp, ...}]
);

-- Refresh token opachi. Si salva solo lo sha256 (esadecimale): un dump del DB
-- non permette di impersonare nessuno.
create table public.sessions (
  token_hash text primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index sessions_profile_idx on public.sessions (profile_id);

-- -----------------------------------------------------------------------------
-- upsert_google_account — primo login o login successivo (rimpiazza il trigger).
-- Idempotente, atomica. Ritorna il bundle che il master serve al client in AUTH_OK.
-- -----------------------------------------------------------------------------

create function public.upsert_google_account(
  p_sub   text,
  p_email text,
  p_name  text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id     uuid;
  v_base   text;
  v_final  text;
  v_suffix int := 0;
begin
  select id into v_id from public.profiles where google_sub = p_sub;

  if v_id is null then
    v_base := coalesce(nullif(trim(p_name), ''), 'player_' || left(md5(p_sub), 8));
    -- username e' unique: due account Google possono condividere il nome visibile,
    -- quindi si de-duplica invece di far fallire l'intero login.
    v_final := v_base;
    while exists (select 1 from public.profiles where username = v_final) loop
      v_suffix := v_suffix + 1;
      v_final := v_base || '_' || v_suffix::text;
    end loop;

    insert into public.profiles (google_sub, email, username)
      values (p_sub, p_email, v_final)
      returning id into v_id;
    insert into public.player_stats (profile_id) values (v_id);
    insert into public.owned_civs (profile_id, civ_id, source)
      values (v_id, 'roman', 'default'), (v_id, 'gaul', 'default');
  else
    update public.profiles set email = coalesce(p_email, email) where id = v_id;
  end if;

  return public._account_bundle(v_id);
end $$;

-- Bundle comune a upsert_google_account e redeem_refresh_token.
create function public._account_bundle(p_id uuid) returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id',       p.id,
    'username', p.username,
    'profile',  jsonb_build_object(
                  'favourite_origin', p.favourite_origin,
                  'favourite_hero',   p.favourite_hero),
    'stats',    jsonb_build_object(
                  'matches_played', s.matches_played,
                  'wins', s.wins, 'top4', s.top4, 'mmr', s.mmr),
    'owned_civs', coalesce(
                  (select jsonb_agg(c.civ_id order by c.acquired_at)
                     from public.owned_civs c where c.profile_id = p.id),
                  '[]'::jsonb))
  from public.profiles p
  join public.player_stats s on s.profile_id = p.id
  where p.id = p_id;
$$;

-- -----------------------------------------------------------------------------
-- Refresh token
-- -----------------------------------------------------------------------------

create function public.store_refresh_token(
  p_profile uuid, p_hash text, p_ttl_days int
) returns void
language sql
security definer
set search_path = public
as $$
  insert into public.sessions (token_hash, profile_id, expires_at)
  values (p_hash, p_profile, now() + make_interval(days => p_ttl_days));
$$;

-- Rotazione: consuma il vecchio hash e ritorna il bundle del profilo, oppure
-- null se il token e' assente o scaduto. Atomica.
create function public.redeem_refresh_token(p_hash text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  delete from public.sessions
    where token_hash = p_hash and expires_at > now()
    returning profile_id into v_id;
  if v_id is null then
    return null;
  end if;
  return public._account_bundle(v_id);
end $$;

create function public.purge_expired_sessions() returns void
language sql
security definer
set search_path = public
as $$ delete from public.sessions where expires_at < now(); $$;

-- Cancellazione account (GDPR + requisito Play Store). Il cascade su profiles
-- pulisce player_stats, owned_civs e sessions. match_history NON ha una FK
-- verso profiles (contiene un jsonb con i profile_id), quindi le partite storiche
-- restano ma con riferimenti a un profilo che non esiste piu'.
create function public.delete_account(p_id uuid) returns void
language sql
security definer
set search_path = public
as $$ delete from public.profiles where id = p_id; $$;

-- -----------------------------------------------------------------------------
-- record_match_result — scrittura atomica di fine partita.
--
-- PostgREST non ha transazioni multi-tabella dal REST, quindi il server invoca
-- questa funzione (SECURITY DEFINER) con POST /rpc/record_match_result: gira
-- tutta server-side in una transazione implicita — upsert match_history, poi
-- incrementa i contatori di ogni umano. Invocata da server/stats_writer.gd.
--
-- p_results: [{profile_id, placement, hp, hero_id, top4(bool), won(bool)}, ...]
--            (solo posti umani; i bot non hanno un profilo)
-- -----------------------------------------------------------------------------

create function public.record_match_result(
  p_match_id text,
  p_seed     bigint,
  p_ranked   boolean,
  p_results  jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r         jsonb;
  v_profile uuid;
begin
  insert into public.match_history (match_id, seed, ranked, ended_at, results)
  values (p_match_id, p_seed, p_ranked, now(), coalesce(p_results, '[]'::jsonb))
  on conflict (match_id) do update
    set seed = excluded.seed, ranked = excluded.ranked,
        ended_at = excluded.ended_at, results = excluded.results;

  -- lobby non-ranked (es. 1 umano + 7 bot): registrate per cronologia ma non
  -- muovono i contatori competitivi.
  if not coalesce(p_ranked, false) then
    return;
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    begin
      v_profile := (r->>'profile_id')::uuid;
    exception when others then
      continue;  -- profile_id assente / malformato: salta la riga
    end;

    update public.player_stats set
      matches_played = matches_played + 1,
      wins  = wins  + case when coalesce((r->>'won')::boolean,  false) then 1 else 0 end,
      top4  = top4  + case when coalesce((r->>'top4')::boolean, false) then 1 else 0 end,
      updated_at = now()
    where profile_id = v_profile;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Ruoli e grant.
--
-- autochess_app  : il ruolo con cui gira ogni query di master e worker.
-- autochess_auth : ruolo di connessione di PostgREST (login), NOINHERIT, fa
--                  SET ROLE ad autochess_app (db-anon-role in postgrest.conf).
-- Le password vanno sostituite al deploy — vedi SETUP_DB.md.
-- -----------------------------------------------------------------------------

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'autochess_app') then
    create role autochess_app nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'autochess_auth') then
    create role autochess_auth noinherit login password 'CHANGE_ME';
  end if;
end $$;
grant autochess_app to autochess_auth;

revoke all on schema public from public;
grant usage on schema public to autochess_app;

grant select, update (favourite_origin, favourite_hero) on public.profiles to autochess_app;
grant select on public.player_stats, public.owned_civs to autochess_app;
grant select, insert on public.match_history to autochess_app;
grant select, insert, delete on public.sessions to autochess_app;

grant execute on function public.upsert_google_account(text, text, text)           to autochess_app;
grant execute on function public.store_refresh_token(uuid, text, int)              to autochess_app;
grant execute on function public.redeem_refresh_token(text)                        to autochess_app;
grant execute on function public.purge_expired_sessions()                          to autochess_app;
grant execute on function public.delete_account(uuid)                              to autochess_app;
grant execute on function public.record_match_result(text, bigint, boolean, jsonb) to autochess_app;
-- _account_bundle e' un helper interno: solo le funzioni SECURITY DEFINER sopra
-- la chiamano (girano come owner), autochess_app non ha bisogno del grant.
revoke all on function public._account_bundle(uuid) from public;
