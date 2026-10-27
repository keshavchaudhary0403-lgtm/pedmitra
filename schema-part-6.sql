-- ============================================================
--  PedMitra — part 6
--
--  Why the trees vanish at the India view. The real reason.
--
--  I first blamed the map's corners running past 180 degrees.
--  Clamping them was worth doing, but it wasn't the bug.
--
--  The bug is that the search rectangle was being treated as a
--  shape on a SPHERE. On a sphere, the straight line between
--  two points at the same latitude is not a line of latitude --
--  it bows towards the pole. So the "rectangle" covering India
--  had a bottom edge that curved UP through the middle of the
--  country, and every tree sitting in that curve fell outside
--  the search area. Zoom in and the rectangle gets small, the
--  curve gets negligible, and the trees reappear.
--
--  The fix: ask the question on a flat map instead of a globe.
--  For "what is inside this rectangle on screen", flat is not
--  an approximation -- it is the correct question, because the
--  screen IS flat.
--
--  Run AFTER parts 1-5.
-- ============================================================

set search_path = public, extensions;

-- An index for asking the flat question quickly.
create index if not exists trees_geom_idx
  on trees using gist ((location::geometry));


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
           greatest(min_lat,  -90.0) as s,
           least   (max_lat,   90.0) as n
  )
  select t.tree_no,
         coalesce(nullif(t.species_other, ''), sp.common_name),
         ST_Y(t.location::geometry),
         ST_X(t.location::geometry),
         care_state(t),
         t.planted_on,
         coalesce(p.display_name, 'Someone')
    from trees t
    join species  sp on sp.id = t.species_id
    join profiles p  on p.id  = t.planter_id
    cross join box b
   where t.flagged = false
     and b.e > b.w and b.n > b.s
     -- flat rectangle, flat comparison. && uses the index above.
     and (t.location::geometry) && ST_MakeEnvelope(b.w, b.s, b.e, b.n, 4326)
   limit max_rows;
$$;


-- ------------------------------------------------------------
-- A blunt fallback, for when the map is showing the whole
-- country and you simply want every tree there is.
-- ------------------------------------------------------------
create or replace function all_trees(max_rows int default 5000)
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
  select t.tree_no,
         coalesce(nullif(t.species_other, ''), sp.common_name),
         ST_Y(t.location::geometry),
         ST_X(t.location::geometry),
         care_state(t),
         t.planted_on,
         coalesce(p.display_name, 'Someone')
    from trees t
    join species  sp on sp.id = t.species_id
    join profiles p  on p.id  = t.planter_id
   where t.flagged = false
   order by t.tree_no desc
   limit max_rows;
$$;

-- ============================================================
--  Check it. This should return every PUBLIC tree you have:
--
--      select * from all_trees();
--
--  And this should return the same ones, since it covers India:
--
--      select * from trees_in_view(60, 5, 100, 40);
--
--  If the first has rows and the second doesn't, tell me.
--  If BOTH are empty, your trees are marked private -- which
--  is not a bug, it is the privacy rule doing its job.
-- ============================================================
