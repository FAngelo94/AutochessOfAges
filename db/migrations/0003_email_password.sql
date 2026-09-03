-- =============================================================================
-- 0003_email_password.sql — account con email e password accanto a Google
-- =============================================================================
--
-- Fino a 0001 l'identita' era solo Google (profiles.google_sub not null). Qui
-- google_sub diventa nullable e compare password_hash: un profilo puo' esistere
-- con l'uno, con l'altro, mai con nessuno dei due (vincolo in fondo).
--
-- Le password sono hashate con bcrypt di pgcrypto (crypt + gen_salt('bf', 10)),
-- gia' installata in 0001 per gen_random_uuid(). Il confronto avviene DENTRO al
-- database: la password in chiaro non esce mai da qui e non viene mai loggata.
-- =============================================================================

alter table public.profiles alter column google_sub drop not null;
alter table public.profiles add column password_hash text;

-- Un account per email. Parziale perche' un profilo Google puo' non avere email.
-- Postgres ammette piu' NULL in un indice unico, quindi gli account email non
-- collidono fra loro su google_sub rimasto nullo.
create unique index profiles_email_lower_idx
  on public.profiles (lower(email)) where email is not null;

-- Un profilo deve avere almeno un modo per autenticarsi.
alter table public.profiles add constraint profiles_has_credential
  check (google_sub is not null or password_hash is not null);


-- -----------------------------------------------------------------------------
-- register_email_account — creazione account con email e password.
-- Ritorna il bundle di _account_bundle, oppure {"error": "..."} se rifiutata.
-- Idempotente non lo e' e non deve esserlo: la seconda registrazione con la
-- stessa email e' un errore, non un login.
-- -----------------------------------------------------------------------------
create function public.register_email_account(
  p_email    text,
  p_password text,
  p_username text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email  text := lower(trim(p_email));
  v_id     uuid;
  v_base   text;
  v_final  text;
  v_suffix int := 0;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
     or length(p_password) < 8 then
    return jsonb_build_object('error', 'invalid');
  end if;

  if exists (select 1 from public.profiles where lower(email) = v_email) then
    return jsonb_build_object('error', 'email_taken');
  end if;

  -- username e' unique: si de-duplica invece di far fallire la registrazione.
  -- Stessa logica di upsert_google_account (0001).
  v_base := coalesce(nullif(trim(p_username), ''), 'player_' || left(md5(v_email), 8));
  v_final := v_base;
  while exists (select 1 from public.profiles where username = v_final) loop
    v_suffix := v_suffix + 1;
    v_final := v_base || '_' || v_suffix::text;
  end loop;

  insert into public.profiles (email, username, password_hash)
    values (v_email, v_final, crypt(p_password, gen_salt('bf', 10)))
    returning id into v_id;
  insert into public.player_stats (profile_id) values (v_id);
  insert into public.owned_civs (profile_id, civ_id, source)
    values (v_id, 'roman', 'default'), (v_id, 'gaul', 'default');

  return public._account_bundle(v_id);
end $$;


-- -----------------------------------------------------------------------------
-- login_email_account — verifica le credenziali, ritorna il bundle o null.
--
-- null copre indistintamente "email inesistente" e "password sbagliata": dire
-- quale delle due e' l'enumerazione degli account registrati.
-- -----------------------------------------------------------------------------
create function public.login_email_account(
  p_email    text,
  p_password text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  select id into v_id from public.profiles
   where lower(email) = lower(trim(p_email))
     and password_hash is not null
     and password_hash = crypt(p_password, password_hash);
  if v_id is null then
    return null;
  end if;
  return public._account_bundle(v_id);
end $$;


-- -----------------------------------------------------------------------------
-- Grant (stesso schema di 0001: autochess_app e' il ruolo di master e worker).
-- -----------------------------------------------------------------------------
grant insert on public.profiles to autochess_app;
grant execute on function public.register_email_account(text, text, text) to autochess_app;
grant execute on function public.login_email_account(text, text)          to autochess_app;
