-- Seed per lo sviluppo LOCALE (`supabase db reset` lo applica dopo le migrazioni).
--
-- Non si possono inserire righe in public.profiles a mano in modo utile: la
-- chiave esterna punta ad auth.users, e il trigger on_auth_user_created crea già
-- profilo + stats + civiltà. Il modo corretto di avere utenti di test in locale:
--
--   1. `supabase start`
--   2. apri Studio su http://localhost:54323 → Authentication → Add user
--      (oppure usa l'endpoint /auth/v1/signup con email+password)
--   3. il trigger popola automaticamente profiles / player_stats / owned_civs
--
-- Questo file resta volutamente quasi vuoto. Aggiungi qui SOLO dati che non
-- dipendono da auth.users (nessuno, per ora).

-- esempio: una partita di cronologia fittizia, utile per provare le query
insert into public.match_history (match_id, seed, ranked, ended_at, results)
values ('dev-seed-match-0001', 123456789, false, now(), '[]'::jsonb)
on conflict (match_id) do nothing;
