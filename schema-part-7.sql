-- ============================================================
--  PedMitra — part 7: make the registry actually live
--
--  Supabase can push a message to every open browser the moment
--  a row changes. This switches that on for the two tables the
--  front page cares about.
--
--  Privacy is unaffected. Realtime obeys the same security rules
--  as everything else: a browser is only told about rows it was
--  already allowed to read. A tree at somebody's home stays
--  invisible -- no message about it is ever sent to anyone else.
--
--  Run AFTER parts 1-6.
-- ============================================================

-- Trees: a new one registered, or one marked as dead.
alter publication supabase_realtime add table public.trees;

-- Care logs: somebody watered something.
alter publication supabase_realtime add table public.care_logs;


-- ------------------------------------------------------------
--  If either line above errors with "already member of
--  publication", that is fine -- it means it was already on.
--  Carry on.
--
--  To check what is being broadcast:
--
--    select tablename
--      from pg_publication_tables
--     where pubname = 'supabase_realtime';
--
--  You should see trees and care_logs in the list.
-- ============================================================
