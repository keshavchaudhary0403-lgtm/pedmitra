-- ============================================================
--  PedMitra — part 8
--
--  Two things:
--   1. Renumber the 7 real trees to 1..7 (closing the gaps left
--      by attempts that were rejected by the 3-metre rule).
--   2. Stop it happening again: check for a duplicate BEFORE a
--      number is handed out, not during the save.
--
--  This is safe ONLY because no strangers have planted yet.
--  Nothing else in the database points at tree_no -- photos,
--  waterings and adoptions all reference a tree's internal id
--  (a UUID), which does not change. So renumbering breaks
--  nothing.
--
--  Run AFTER parts 1-7. Run it ONCE.
-- ============================================================

set search_path = public, extensions;

begin;

-- ------------------------------------------------------------
-- 1. Renumber, oldest planting first, into 1..7.
--
--    Done in two passes so we never collide with a number that
--    is still in use. First shove everything up into the
--    millions (empty space), then bring it back down in order.
-- ------------------------------------------------------------

-- pass one: park every tree somewhere nothing else lives
update trees
   set tree_no = tree_no + 1000000;

-- pass two: hand out 1, 2, 3... in the order they were planted
with ordered as (
  select id,
         row_number() over (order by created_at, tree_no) as new_no
    from trees
)
update trees t
   set tree_no = o.new_no
  from ordered o
 where t.id = o.id;


-- ------------------------------------------------------------
-- 2. Point the counter at the next free number.
--
--    tree_no is an identity column, backed by a sequence. After
--    renumbering, that sequence still thinks it's at 11. Set it
--    so the NEXT tree registered is one past the highest we now
--    have -- i.e. #8 if there are 7 trees.
-- ------------------------------------------------------------
select setval(
  pg_get_serial_sequence('trees', 'tree_no'),
  (select max(tree_no) from trees),
  true          -- 'true' = the next value will be max + 1
);


-- ------------------------------------------------------------
-- 3. Stop rejected trees from eating numbers.
--
--    The 3-metre rule was a trigger that fired DURING the insert
--    -- by which point a number had already been drawn from the
--    sequence. When the trigger then rejected the row, the row
--    vanished but the number was already spent.
--
--    Fix: check for a clash inside register_tree, BEFORE the
--    insert. No insert, no number drawn. And drop the trigger,
--    so the check only lives in one place.
-- ------------------------------------------------------------

drop trigger if exists trees_no_duplicate on trees;

create or replace function register_tree(
  p_species_id    text,
  p_lat           double precision,
  p_lng           double precision,
  p_photo_url     text,
  p_accuracy_m    numeric  default null,
  p_campaign_tag  text     default null,
  p_notes         text     default null,
  p_planted_on    date     default current_date,
  p_is_public     boolean  default true,
  p_species_other text     default null
)
returns bigint
language plpgsql
set search_path = public, extensions
as $$
declare
  new_id   uuid;
  new_no   bigint;
  clash_no bigint;
  here     geography := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in first.';
  end if;

  -- The duplicate check happens FIRST, before any row is inserted,
  -- so a rejected tree never draws a number.
  --   - home trees are never checked (a balcony holds many pots)
  --   - public trees are checked only against other PUBLIC trees,
  --     so a private tree can never block one, nor be revealed by
  --     the error message.
  if coalesce(p_is_public, true) then
    select tree_no into clash_no
      from trees
     where is_public = true
       and ST_DWithin(location, here, 3)
     limit 1;

    if clash_no is not null then
      raise exception 'A tree is already registered here (Tree #%). Water that one instead.', clash_no;
    end if;
  end if;

  insert into trees (planter_id, species_id, species_other, location, gps_accuracy_m,
                     planted_on, campaign_tag, notes, is_public)
  values (auth.uid(), p_species_id,
          nullif(trim(coalesce(p_species_other, '')), ''),
          here, p_accuracy_m, p_planted_on,
          nullif(p_campaign_tag, ''), nullif(p_notes, ''),
          coalesce(p_is_public, true))
  returning id, tree_no into new_id, new_no;

  if p_photo_url is not null and p_photo_url <> '' then
    insert into tree_photos (tree_id, uploaded_by, url, is_primary)
    values (new_id, auth.uid(), p_photo_url, true);
  end if;

  return new_no;
end;
$$;

commit;

-- ============================================================
--  Check it worked:
--
--    select tree_no, created_at from trees order by tree_no;
--
--  You should now see 1, 2, 3, 4, 5, 6, 7 with no gaps.
--  The next tree anyone registers will be #8.
--
--  A gap can still appear if an insert fails AFTER numbering
--  (a photo upload dying, two people hitting the same spot in
--  the same instant). That is rare and harmless. What we have
--  killed is the common cause -- the 3-metre rejection, which
--  was burning a number every single time.
-- ============================================================
