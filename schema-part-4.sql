-- ============================================================
--  PedMitra — part 4: My Trees, and the timeline
--
--  A tree with one photo is a record.
--  A tree with twenty photos, taken across three years by six
--  people who never met, is something else entirely.
--
--  Run AFTER parts 1, 2 and 3.
-- ============================================================

set search_path = public, extensions;


-- ------------------------------------------------------------
-- 1. Every tree you have planted.
--    Private ones included -- they're yours, you can see them.
-- ------------------------------------------------------------
create or replace function my_trees()
returns table (
  tree_no     bigint,
  species     text,
  lat         double precision,
  lng         double precision,
  state       text,
  is_public   boolean,
  planted_on  date,
  last_cared  timestamptz,
  photo       text,
  care_count  int,
  days_dry    int
)
language sql
stable
set search_path = public, extensions
as $$
  select t.tree_no,
         coalesce(nullif(t.species_other,''), s.common_name),
         ST_Y(t.location::geometry),
         ST_X(t.location::geometry),
         care_state(t),
         t.is_public,
         t.planted_on,
         t.last_cared_at,
         (select ph.url from tree_photos ph
           where ph.tree_id = t.id order by ph.created_at asc limit 1),
         (select count(*)::int from care_logs c where c.tree_id = t.id),
         extract(day from now() - coalesce(t.last_cared_at, t.created_at))::int
    from trees t
    join species s on s.id = t.species_id
   where t.planter_id = auth.uid()
   order by t.tree_no desc;
$$;


-- ------------------------------------------------------------
-- 2. Every tree you've adopted but didn't plant.
--    Somebody else's tree that you decided to look after.
-- ------------------------------------------------------------
create or replace function my_adopted()
returns table (
  tree_no     bigint,
  species     text,
  lat         double precision,
  lng         double precision,
  state       text,
  planter     text,
  last_cared  timestamptz,
  photo       text,
  days_dry    int
)
language sql
stable
set search_path = public, extensions
as $$
  select t.tree_no,
         coalesce(nullif(t.species_other,''), s.common_name),
         ST_Y(t.location::geometry),
         ST_X(t.location::geometry),
         care_state(t),
         coalesce(p.display_name, 'Someone'),
         t.last_cared_at,
         (select ph.url from tree_photos ph
           where ph.tree_id = t.id order by ph.created_at asc limit 1),
         extract(day from now() - coalesce(t.last_cared_at, t.created_at))::int
    from adoptions a
    join trees    t on t.id = a.tree_id
    join species  s on s.id = t.species_id
    join profiles p on p.id = t.planter_id
   where a.user_id = auth.uid()
     and t.planter_id <> auth.uid()
   order by coalesce(t.last_cared_at, t.created_at) asc;
$$;


-- ------------------------------------------------------------
-- 3. The life of one tree, in order.
--
--    Planting, every photograph, every watering, every time
--    somebody said it was struggling. One list, newest first.
--    Anyone may read it -- for a private tree, the security
--    rules already mean "anyone" is only the planter.
-- ------------------------------------------------------------
create or replace function timeline(p_tree_no bigint)
returns json
language sql
stable
set search_path = public
as $$
  with t as (select * from trees where tree_no = p_tree_no),
  events as (
    select 'planted' as kind,
           t.created_at as at,
           coalesce(p.display_name, 'Someone') as who,
           null::text as url,
           null::text as action,
           null::text as note
      from t join profiles p on p.id = t.planter_id

    union all

    select 'photo', ph.created_at, coalesce(pr.display_name, 'Someone'),
           ph.url, null, null
      from t
      join tree_photos ph on ph.tree_id = t.id
      join profiles pr    on pr.id = ph.uploaded_by

    union all

    select 'care', c.created_at, coalesce(pr.display_name, 'Someone'),
           null, c.action, c.note
      from t
      join care_logs c on c.tree_id = t.id
      join profiles pr on pr.id = c.user_id
  )
  select coalesce(
    json_agg(json_build_object(
      'kind', kind, 'at', at, 'who', who,
      'url', url, 'action', action, 'note', note
    ) order by at desc), '[]'::json)
  from events;
$$;


-- ------------------------------------------------------------
-- 4. Add a photograph to a tree -- anybody's tree.
--
--    This is what builds the timeline. You walk past a Neem
--    somebody registered two years ago, you take a picture,
--    and it joins the record. You need not have planted it and
--    you need not tell anyone.
--
--    If you can't see the tree (it's private and not yours),
--    the lookup finds nothing and this refuses.
-- ------------------------------------------------------------
create or replace function add_photo(p_tree_no bigint, p_url text)
returns void
language plpgsql
set search_path = public
as $$
declare
  t_id uuid;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in first.';
  end if;

  select id into t_id from trees where tree_no = p_tree_no;
  if t_id is null then
    raise exception 'No tree with that number.';
  end if;

  insert into tree_photos (tree_id, uploaded_by, url, is_primary)
  values (t_id, auth.uid(), p_url, false);
end;
$$;


-- ------------------------------------------------------------
-- 5. A watering with a photo now feeds the timeline too.
--    One source of truth for pictures: tree_photos.
-- ------------------------------------------------------------
create or replace function log_care(
  p_tree_no bigint,
  p_action  text default 'watered',
  p_health  text default null,
  p_note    text default null,
  p_photo   text default null
)
returns void
language plpgsql
set search_path = public
as $$
declare
  t_id uuid;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in first.';
  end if;

  select id into t_id from trees where tree_no = p_tree_no;
  if t_id is null then
    raise exception 'No tree with that number.';
  end if;

  insert into care_logs (tree_id, user_id, action, health_rating, note, photo_url)
  values (t_id, auth.uid(), p_action, nullif(p_health,''), nullif(p_note,''), nullif(p_photo,''));

  if p_photo is not null and p_photo <> '' then
    insert into tree_photos (tree_id, uploaded_by, url, is_primary)
    values (t_id, auth.uid(), p_photo, false);
  end if;
end;
$$;

-- ============================================================
--  Done.
-- ============================================================
