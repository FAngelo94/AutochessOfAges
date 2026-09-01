-- Seed per lo sviluppo LOCALE. Applicalo a mano dopo db/apply.sh:
--
--   psql "$DB_URL" -f db/seed.sql
--
-- Non serve un vero login Google per avere dati di prova: si inserisce un
-- account fittizio come farebbe upsert_google_account().

select public.upsert_google_account('dev-sub-0001', 'dev@example.com', 'Sviluppatore');

insert into public.match_history (match_id, seed, ranked, ended_at, results)
values ('dev-seed-match-0001', 123456789, false, now(), '[]'::jsonb)
on conflict (match_id) do nothing;
