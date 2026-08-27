-- =============================================================================
-- 0001_initial.sql  —  Autochess Of Ages, initial public schema (Postgres 15)
-- =============================================================================
--
-- SECURITY MODEL — read before changing anything here.
--
-- The mobile client authenticates against Supabase with the *anon key*. That key
-- is embedded in the APK / web bundle and must be considered public: anyone can
-- extract it. The ONLY thing standing between that key and the whole database is
-- Row Level Security (RLS). Every table below has RLS enabled, and the client
-- can only ever see or change its own rows.
--
-- Competitive state (player_stats, owned_civs, match_history) has NO write
-- policy at all. The client cannot INSERT / UPDATE / DELETE those tables. They
-- are written exclusively by the trusted game server using the *service_role*
-- key, which bypasses RLS entirely. match_history has no policy whatsoever, so
-- the client cannot even read it.
--
-- If you add a table, you MUST enable RLS on it and add explicit policies, or it
-- is wide open to every holder of the anon key.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tables  (auth.users is managed by Supabase; we only own schema public)
-- -----------------------------------------------------------------------------

create table public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
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
  source      text not null,                  -- 'default' | 'purchase' | 'promo'
  acquired_at timestamptz not null default now(),
  primary key (profile_id, civ_id)
);

create table public.match_history (
  id         uuid primary key default gen_random_uuid(),
  match_id   text unique,                     -- id assigned by the master; unique for idempotent writes
  seed       bigint not null,
  ranked     boolean not null default true,
  started_at timestamptz not null default now(),
  ended_at   timestamptz,
  results    jsonb not null default '[]'::jsonb  -- [{profile_id, placement, hp, ...}]
);

-- -----------------------------------------------------------------------------
-- First-login trigger — no signup endpoint to write.
-- On every new auth.users row: create the profile, the stats row, and the two
-- default civilizations (roman, gaul). security definer so it runs with the
-- table owner's rights regardless of who triggered the insert.
-- -----------------------------------------------------------------------------

create function public.handle_new_user() returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  base_name  text;
  final_name text;
  suffix     int := 0;
begin
  base_name := coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''),
                        nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
                        'player_' || left(new.id::text, 8));
  -- username is unique: two Google accounts can share a display name, so
  -- de-duplicate rather than let the trigger (and the whole login) fail.
  final_name := base_name;
  while exists (select 1 from public.profiles where username = final_name) loop
    suffix := suffix + 1;
    final_name := base_name || '_' || suffix::text;
  end loop;

  insert into public.profiles (id, username) values (new.id, final_name);
  insert into public.player_stats (profile_id) values (new.id);
  insert into public.owned_civs (profile_id, civ_id, source)
    values (new.id, 'roman', 'default'), (new.id, 'gaul', 'default');
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- Row Level Security — mandatory, not optional.
-- -----------------------------------------------------------------------------

alter table public.profiles      enable row level security;
alter table public.player_stats  enable row level security;
alter table public.owned_civs    enable row level security;
alter table public.match_history enable row level security;

create policy "own profile read"   on public.profiles     for select using (auth.uid() = id);
create policy "own profile update" on public.profiles     for update using (auth.uid() = id) with check (auth.uid() = id);
create policy "own stats read"     on public.player_stats for select using (auth.uid() = profile_id);
create policy "own civs read"      on public.owned_civs   for select using (auth.uid() = profile_id);
-- match_history: no policy at all -> the client reads nothing. Server only (service_role).

-- -----------------------------------------------------------------------------
-- record_match_result — atomic end-of-match write.
--
-- PostgREST has no client-side multi-table transaction, so the game server
-- (service_role) calls this SECURITY DEFINER function via
-- POST /rest/v1/rpc/record_match_result. It runs entirely server-side in one
-- implicit transaction: upsert match_history, then bump each human's counters.
-- Invoked by server/stats_writer.gd. See db/README.md for the payload shape.
--
-- p_results: [{profile_id, placement, hp, hero_id, top4(bool), won(bool)}, ...]
--            (human seats only; bots have no profile)
-- -----------------------------------------------------------------------------

create function public.record_match_result(
  p_match_id text,
  p_seed     bigint,
  p_ranked   boolean,
  p_results  jsonb
) returns void
language plpgsql security definer
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

  -- unranked lobbies (e.g. 1 human + 7 bots) are recorded for history but must
  -- not move competitive counters.
  if not coalesce(p_ranked, false) then
    return;
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    begin
      v_profile := (r->>'profile_id')::uuid;
    exception when others then
      continue;  -- missing / malformed profile_id: skip this row
    end;

    update public.player_stats set
      matches_played = matches_played + 1,
      wins  = wins  + case when coalesce((r->>'won')::boolean,  false) then 1 else 0 end,
      top4  = top4  + case when coalesce((r->>'top4')::boolean, false) then 1 else 0 end,
      updated_at = now()
    where profile_id = v_profile;
  end loop;
end $$;

-- authenticated / anon must NOT be able to call this (they could forge stats).
revoke all on function public.record_match_result(text, bigint, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.record_match_result(text, bigint, boolean, jsonb) to service_role;
