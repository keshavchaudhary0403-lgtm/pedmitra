-- ============================================================
--  PedMitra — part 5
--
--  1. A balcony can hold ten pots in two square metres.
--     The three-metre rule was written for streets, not homes.
--  2. "Other" needs somewhere to write the name down.
--
--  Run AFTER parts 1-4.
-- ============================================================

set search_path = public, extensions;


-- ------------------------------------------------------------
-- 1. The three-metre rule, corrected.
--
--    It exists to stop two people registering the same street
--    tree twice, and to make lazy fakes harder. Neither applies
--    to a balcony. So:
--
--      - A private tree is never checked. Plant fifty in a pot.
--      - A public tree is checked only against OTHER PUBLIC
--        trees. It must never be blocked by somebody's balcony,
--        because saying "a tree is already here" would tell a
--        stranger there is a plant on that person's terrace.
-- ------------------------------------------------------------
create or replace function reject_duplicate_tree()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  clash_no bigint;
begin
  -- Home trees: no check at all.
  if new.is_public = false then
    return new;
  end if;

  -- Public trees: only public trees can stand in their way.
  select tree_no into clash_no
    from trees
   where is_public = true
     and ST_DWithin(location, new.location, 3)
   limit 1;

  if clash_no is not null then
    raise exception 'A tree is already registered here (Tree #%). Water that one instead.', clash_no;
  end if;

  return new;
end;
$$;


-- ------------------------------------------------------------
-- 2. Registering a tree can now carry its own name.
--    For when it isn't on our list, or when you'd rather call
--    it what you call it.
-- ------------------------------------------------------------
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
  new_id uuid;
  new_no bigint;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in first.';
  end if;

  insert into trees (planter_id, species_id, species_other, location, gps_accuracy_m,
                     planted_on, campaign_tag, notes, is_public)
  values (auth.uid(), p_species_id,
          nullif(trim(coalesce(p_species_other, '')), ''),
          ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
          p_accuracy_m, p_planted_on,
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


-- ------------------------------------------------------------
-- 3. The map, at the whole-country view.
--
--    The old query was handed the corners of the visible map.
--    Zoomed out to India, those corners run past the edge of
--    the world (beyond 180 degrees), which makes the rectangle
--    nonsense and the query returns nothing. That is why trees
--    only appeared once you zoomed in.
--
--    This clamps the rectangle to the actual planet before
--    asking. It also raises the ceiling, so a whole-country
--    view isn't quietly truncated.
-- ------------------------------------------------------------
create or replace function trees_in_view(
  min_lng  double precision,
  min_lat  double precision,
  max_lng  double precision,
  max_lat  double precision,
  max_rows int default 5000
)
returns table (
  tree_no    bigint,
  species    text,
  lat        double precision,
  lng        double precision,
  state      text,
  planted_on date,
  planter    text
)
language sql
stable
set search_path = public, extensions
as $$
  with box as (
    select greatest(min_lng, -180.0) as w,
           least   (max_lng,  180.0) as e,
           greatest(min_lat,  -85.0) as s,
           least   (max_lat,   85.0) as n
  )
  select t.tree_no,
         coalesce(nullif(t.species_other, ''), s.common_name),
         ST_Y(t.location::geometry),
         ST_X(t.location::geometry),
         care_state(t),
         t.planted_on,
         coalesce(p.display_name, 'Someone')
    from trees t
    join species  s on s.id = t.species_id
    join profiles p on p.id = t.planter_id
    cross join box b
   where t.flagged = false
     and b.e > b.w and b.n > b.s
     and ST_Intersects(
           t.location,
           ST_MakeEnvelope(b.w, b.s, b.e, b.n, 4326)::geography)
   limit max_rows;
$$;

-- ============================================================
--  Done.
--
--  Try it: register two plants on your balcony, a metre apart,
--  both marked "inside my home". Both should go through.
-- ============================================================
