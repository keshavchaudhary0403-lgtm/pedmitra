-- ============================================================
--  PedMitra — part 10: watering someone else's tree counts
--
--  Logging a watering inserts into care_logs, and a trigger on
--  care_logs then stamps trees.last_cared_at. That trigger ran
--  as the person watering, and the security rules only let a
--  tree's planter change a tree. So when you watered somebody
--  else's tree the log was saved but the stamp was silently
--  skipped -- the tree kept saying "Needs water".
--
--  This makes the care_logs trigger functions run as the owner
--  of the database, the same way a tree's planter already could.
--  They only ever touch the tree the new log belongs to, and
--  log_care() still checks the caller can see that tree first.
--
--  Then it repairs every tree that missed a watering.
--
--  Run AFTER parts 1-9.
--  Supabase -> SQL Editor -> New query -> paste -> Run.
-- ============================================================

set search_path = public, extensions;


-- ------------------------------------------------------------
-- 1. Let the care_logs trigger(s) update the tree.
-- ------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select distinct p.oid::regprocedure as fn
      from pg_trigger tg
      join pg_proc p on p.oid = tg.tgfoid
     where tg.tgrelid = 'public.care_logs'::regclass
       and not tg.tgisinternal
  loop
    execute format('alter function %s security definer set search_path = public, extensions', r.fn);
    raise notice 'Fixed trigger function %', r.fn;
  end loop;
end $$;


-- ------------------------------------------------------------
-- 2. Repair trees whose last watering was never stamped.
--    Only ever moves the date forward.
-- ------------------------------------------------------------
update trees t
   set last_cared_at = w.last_watered
  from (select tree_id, max(created_at) as last_watered
          from care_logs
         where action = 'watered'
         group by tree_id) w
 where w.tree_id = t.id
   and (t.last_cared_at is null or t.last_cared_at < w.last_watered);


-- ------------------------------------------------------------
--  To check: the trigger function(s) should now show
--  security_definer = true.
--
--    select p.proname, p.prosecdef as security_definer
--      from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
--     where tg.tgrelid = 'public.care_logs'::regclass
--       and not tg.tgisinternal;
-- ============================================================
