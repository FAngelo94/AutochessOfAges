-- =============================================================================
-- 0005_donations.sql — Crowdfunding Store: donazioni attribuite a un account.
-- =============================================================================
--
-- Il negozio non vende più contenuti: raccoglie donazioni verso un obiettivo,
-- e la barra di avanzamento è pubblica. Questo cambia chi può scrivere il dato.
--
--   * La riga la scrive il WEBHOOK di RevenueCat, non il client. Un totale
--     mostrato a tutti e sommato da chi paga sarebbe gonfiabile da chiunque
--     sappia aprire un socket; il webhook arriva dal server di RevenueCat e
--     porta l'importo che è stato davvero addebitato.
--   * `transaction_id` è UNIQUE perché RevenueCat ritenta i webhook finché non
--     riceve un 2xx: senza il vincolo, un ritentativo raddoppierebbe la cifra
--     raccolta. L'inserimento è `on conflict do nothing`, quindi ritentare è
--     gratuito e idempotente.
--   * `environment` distingue SANDBOX da PRODUCTION, e il totale pubblico conta
--     SOLO le righe di produzione. Non è pedanteria: la SDK key sta in un repo
--     pubblico (e comunque dentro l'APK), quindi chiunque può configurare
--     un'app contro lo stesso progetto RevenueCat e generare acquisti di prova.
--     Quegli eventi arrivano a questo webhook: se contassero, la barra sarebbe
--     gonfiabile da un estraneo senza spendere un centesimo. Le righe sandbox
--     si scrivono lo stesso — servono a verificare che la catena funzioni — ma
--     restano fuori dal totale.
--   * `user_id` è una FK con `on delete set null`, non `cascade`: cancellare
--     l'account (delete_account in 0001) non deve cancellare la donazione. Il
--     totale raccolto è un fatto contabile, l'identità di chi ha donato no —
--     azzerare l'una preservando l'altro è esattamente ciò che serve, sia per
--     il GDPR sia per la barra.
--
-- L'`app_user_id` che arriva nel webhook è l'id del profilo perché il client
-- chiama Purchases.logIn() al login (monetization/store.gd). Se un giorno
-- arrivasse una donazione da un utente anonimo — pagata prima di accedere —
-- la riga si scrive lo stesso con user_id null: conta nel totale, non nella
-- cronologia personale di nessuno.
-- =============================================================================

create table if not exists public.donations (
  id             bigserial primary key,
  user_id        uuid references public.profiles(id) on delete set null,
  app_user_id    text not null,
  amount_cents   int  not null check (amount_cents > 0),
  currency       text not null default 'EUR',
  store          text not null default 'unknown',
  product_id     text not null default '',
  environment    text not null default 'PRODUCTION',
  transaction_id text not null,
  created_at     timestamptz not null default now(),
  constraint donations_transaction_unique unique (transaction_id)
);

create index if not exists donations_user_idx    on public.donations (user_id);
create index if not exists donations_created_idx on public.donations (created_at desc);


-- -----------------------------------------------------------------------------
-- record_donation — punto di ingresso del webhook. Idempotente.
-- -----------------------------------------------------------------------------
--
-- Ritorna jsonb {inserted, total_cents}: `inserted=false` significa che quel
-- `transaction_id` era già stato registrato — un ritentativo, non un errore, e
-- il master deve rispondere 2xx lo stesso o RevenueCat continuerà a ritentare.

create or replace function public.record_donation(
  p_app_user_id    text,
  p_amount_cents   int,
  p_currency       text,
  p_store          text,
  p_product_id     text,
  p_transaction_id text,
  p_environment    text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile  uuid;
  v_rows     int := 0;
begin
  if p_transaction_id is null or p_transaction_id = '' then
    return jsonb_build_object('inserted', false, 'error', 'missing_transaction_id');
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    return jsonb_build_object('inserted', false, 'error', 'invalid_amount');
  end if;

  -- app_user_id è l'id del profilo solo quando l'utente aveva fatto il login;
  -- altrimenti è un id anonimo di RevenueCat e non corrisponde a nessuna riga.
  begin
    v_profile := p_app_user_id::uuid;
  exception when invalid_text_representation then
    v_profile := null;
  end;
  if v_profile is not null
     and not exists (select 1 from public.profiles where id = v_profile) then
    v_profile := null;
  end if;

  insert into public.donations (
    user_id, app_user_id, amount_cents, currency, store, product_id,
    environment, transaction_id
  ) values (
    v_profile, coalesce(p_app_user_id, ''), p_amount_cents,
    coalesce(nullif(p_currency, ''), 'EUR'),
    coalesce(nullif(p_store, ''), 'unknown'),
    coalesce(p_product_id, ''),
    case when upper(coalesce(p_environment, '')) = 'SANDBOX' then 'SANDBOX' else 'PRODUCTION' end,
    p_transaction_id
  )
  on conflict (transaction_id) do nothing;

  get diagnostics v_rows = row_count;

  return jsonb_build_object(
    'inserted', v_rows > 0,
    'total_cents', (select coalesce(sum(amount_cents), 0)
                    from public.donations where environment = 'PRODUCTION')
  );
end;
$$;


-- -----------------------------------------------------------------------------
-- donation_summary — ciò che alimenta la barra: totale e numero di sostenitori.
-- -----------------------------------------------------------------------------
--
-- I sostenitori si contano per app_user_id, non per user_id: chi ha donato
-- senza account (o dopo averlo cancellato) resta un sostenitore.
--
-- Solo PRODUCTION: le righe sandbox esistono per verificare la catena, non per
-- muovere una barra che vedono tutti.

create or replace function public.donation_summary()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'total_cents', coalesce(sum(amount_cents), 0),
    'supporters',  count(distinct app_user_id),
    'donations',   count(*)
  )
  from public.donations
  where environment = 'PRODUCTION';
$$;


-- -----------------------------------------------------------------------------
-- player_donations — le proprie donazioni. Stessa forma di player_match_history
-- (0004): il filtro sta DENTRO la funzione, perché la tabella contiene le righe
-- di tutti e un filtro costruito dal chiamante è una fuga di dati a un errore
-- di distanza.
-- -----------------------------------------------------------------------------

create or replace function public.player_donations(p_uid uuid, p_limit int)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(payload order by created_at desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'amount_cents', d.amount_cents,
             'currency',     d.currency,
             'created_at',   d.created_at
           ) as payload,
           d.created_at
    from public.donations d
    where d.user_id = p_uid
      and d.environment = 'PRODUCTION'
    order by d.created_at desc
    limit greatest(1, least(coalesce(p_limit, 20), 100))
  ) s;
$$;


-- -----------------------------------------------------------------------------
-- Grant (ruolo a privilegio minimo, come in 0001/0002/0004)
-- -----------------------------------------------------------------------------
--
-- Nessun grant di INSERT diretto sulla tabella: si scrive solo attraverso
-- record_donation, che è l'unico punto in cui l'idempotenza è garantita.

revoke all on function public.record_donation(text, int, text, text, text, text, text) from public;
revoke all on function public.donation_summary() from public;
revoke all on function public.player_donations(uuid, int) from public;

grant select on public.donations to autochess_app;
grant execute on function public.record_donation(text, int, text, text, text, text, text) to autochess_app;
grant execute on function public.donation_summary() to autochess_app;
grant execute on function public.player_donations(uuid, int) to autochess_app;
