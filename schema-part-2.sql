-- ============================================================
--  PedMitra — part 2: the functions the app calls
--  Run this AFTER the first schema file.
--  Supabase -> SQL Editor -> New query -> paste -> Run.
-- ============================================================

set search_path = public, extensions;


-- ------------------------------------------------------------
-- Register a tree.
-- Returns the permanent tree number.
-- Runs as YOU, so all the security rules still apply and the
-- three-metre rule still fires.
-- ------------------------------------------------------------
create or replace function register_tree(
  p_species_id   text,
  p_lat          double precision,
  p_lng          double precision,
  p_photo_url    text,
  p_accuracy_m   numeric default null,
  p_campaign_tag text    default null,
  p_notes        text    default null,
  p_planted_on   date    default current_date
)
returns bigint
language plpgsql
set search_path = public, extensions
as $$
declare
  new_id  uuid;
  new_no  bigint;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in first.';
  end if;

  insert into trees (planter_id, species_id, location, gps_accuracy_m,
                     planted_on, campaign_tag, notes)
  values (auth.uid(), p_species_id,
          ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
          p_accuracy_m, p_planted_on, nullif(p_campaign_tag,''), nullif(p_notes,''))
  returning id, tree_no into new_id, new_no;

  if p_photo_url is not null and p_photo_url <> '' then
    insert into tree_photos (tree_id, uploaded_by, url, is_primary)
    values (new_id, auth.uid(), p_photo_url, true);
  end if;

  return new_no;
end;
$$;


-- ------------------------------------------------------------
-- Everything about one tree: details, photos, care history.
-- Public — no sign-in needed to look.
-- ------------------------------------------------------------
create or replace function get_tree(p_tree_no bigint)
returns json
language sql
stable
set search_path = public, extensions
as $$
  select json_build_object(
    'tree_no',    t.tree_no,
    'species',    coalesce(nullif(t.species_other,''), s.common_name),
    'botanical',  s.botanical_name,
    'lat',        ST_Y(t.location::geometry),
    'lng',        ST_X(t.location::geometry),
    'planted_on', t.planted_on,
    'planter',    coalesce(p.display_name, 'Someone'),
    'planter_id', t.planter_id,
    'status',     t.status,
    'state',      care_state(t),
    'campaign',   t.campaign_tag,
    'notes',      t.notes,
    'last_cared', t.last_cared_at,
    'photos', coalesce((
      select json_agg(json_build_object('url', ph.url, 'at', ph.created_at)
                      order by ph.created_at desc)
      from tree_photos ph where ph.tree_id = t.id), '[]'::json),
    'care', coalesce((
      select json_agg(json_build_object(
               'action', c.action,
               'by',     coalesce(pr.display_name, 'Someone'),
               'at',     c.created_at,
               'note',   c.note)
             order by c.created_at desc)
      from care_logs c
      join profiles pr on pr.id = c.user_id
      where c.tree_id = t.id), '[]'::json),
    'friends', (select count(*) from adoptions a where a.tree_id = t.id)
  )
  from trees t
  join species  s on s.id = t.species_id
  join profiles p on p.id = t.planter_id
  where t.tree_no = p_tree_no;
$$;


-- ------------------------------------------------------------
-- Water a tree. Anyone's tree. That's the point.
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
end;
$$;


-- ------------------------------------------------------------
-- Adopt / un-adopt a tree.
-- ------------------------------------------------------------
create or replace function toggle_adopt(p_tree_no bigint)
returns boolean
language plpgsql
set search_path = public
as $$
declare
  t_id    uuid;
  existing int;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in first.';
  end if;

  select id into t_id from trees where tree_no = p_tree_no;
  if t_id is null then
    raise exception 'No tree with that number.';
  end if;

  select count(*) into existing
    from adoptions where tree_id = t_id and user_id = auth.uid();

  if existing > 0 then
    delete from adoptions where tree_id = t_id and user_id = auth.uid();
    return false;
  else
    insert into adoptions (user_id, tree_id) values (auth.uid(), t_id);
    return true;
  end if;
end;
$$;


-- ------------------------------------------------------------
-- Your own record.
-- Watering is worth more than planting. Watering a stranger's
-- tree is worth the most. The scoring is the argument.
-- ------------------------------------------------------------
create or replace function my_record()
returns json
language sql
stable
set search_path = public
as $$
  select json_build_object(
    'planted',   (select count(*) from trees where planter_id = auth.uid()),
    'standing',  (select count(*) from trees
                   where planter_id = auth.uid() and status <> 'dead'),
    'cared',     (select count(*) from care_logs where user_id = auth.uid()),
    'adopted',   (select count(*) from adoptions where user_id = auth.uid()),
    'score',
      (select count(*) from trees where planter_id = auth.uid()) * 10
    + (select count(*) from care_logs c join trees t on t.id = c.tree_id
        where c.user_id = auth.uid() and t.planter_id = auth.uid()) * 15
    + (select count(*) from care_logs c join trees t on t.id = c.tree_id
        where c.user_id = auth.uid() and t.planter_id <> auth.uid()) * 25
    + (select count(*) from adoptions where user_id = auth.uid()) * 5
  );
$$;


-- ------------------------------------------------------------
-- The most recently registered trees, for the front page.
-- ------------------------------------------------------------
create or replace function recent_trees(n int default 8)
returns table (
  tree_no  bigint,
  species  text,
  city     text,
  state    text,
  planted  timestamptz
)
language sql
stable
set search_path = public
as $$
  select t.tree_no,
         coalesce(nullif(t.species_other,''), s.common_name),
         coalesce(p.city, ''),
         care_state(t),
         t.created_at
    from trees t
    join species  s on s.id = t.species_id
    join profiles p on p.id = t.planter_id
   where t.flagged = false
   order by t.created_at desc
   limit n;
$$;


-- ------------------------------------------------------------
-- Set your name once, after your first sign-in.
-- ------------------------------------------------------------
create or replace function set_my_name(p_name text, p_city text default null)
returns void
language sql
set search_path = public
as $$
  update profiles
     set display_name = nullif(trim(p_name), ''),
         city         = nullif(trim(p_city), '')
   where id = auth.uid();
$$;

-- ============================================================
--  Done. Test with:  select registry_stats();
-- ============================================================
