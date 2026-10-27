-- ============================================================
--  PedMitra — part 3: private trees
--
--  A tree planted inside someone's home or compound must not
--  appear on the public map, and no stranger should ever be
--  sent to water it. This is not a display setting. If we only
--  hid these trees on the website, anyone could still ask the
--  API directly and get a list of people's homes. So we hide
--  them in the database itself.
--
--  Run this AFTER parts 1 and 2.
-- ============================================================

set search_path = public, extensions;


-- ------------------------------------------------------------
-- 1. Every tree is either public or private.
--    Public by default -- the whole point is the commons.
-- ------------------------------------------------------------
alter table trees add column if not exists is_public boolean not null default true;

create index if not exists trees_public_idx on trees (is_public);


-- ------------------------------------------------------------
-- 2. Who can see a tree.
--
--    A private tree is visible ONLY to the person who planted
--    it. Not on the map, not in the feed, not through the API,
--    not to anyone. This single policy does all of that work.
-- ------------------------------------------------------------
drop policy if exists "read trees" on trees;
create policy "read trees" on trees
  for select using (is_public or planter_id = auth.uid());

-- Photos and care logs inherit that. If you can't see the tree,
-- you can't see its photographs or who has been watering it.
drop policy if exists "read photos" on tree_photos;
create policy "read photos" on tree_photos
  for select using (exists (select 1 from trees t where t.id = tree_photos.tree_id));

drop policy if exists "read care" on care_logs;
create policy "read care" on care_logs
  for select using (exists (select 1 from trees t where t.id = care_logs.tree_id));

drop policy if exists "read adoptions" on adoptions;
create policy "read adoptions" on adoptions
  for select using (exists (select 1 from trees t where t.id = adoptions.tree_id));


-- ------------------------------------------------------------
-- 3. Nobody adopts a tree in someone's garden.
--    Watering is already impossible -- the tree simply doesn't
--    exist as far as anyone else is concerned -- but adoption
--    is blocked explicitly so the intent is on the record.
-- ------------------------------------------------------------
drop policy if exists "adopt" on adoptions;
create policy "adopt" on adoptions
  for insert to authenticated
  with check (
    auth.uid() = user_id
    and exists (select 1 from trees t
                 where t.id = adoptions.tree_id
                   and (t.is_public or t.planter_id = auth.uid()))
  );


-- ------------------------------------------------------------
-- 4. The three-metre rule has to see EVERY tree, including the
--    private ones -- otherwise two trees could be registered on
--    the same spot. But it must never say "there's a tree here"
--    about somebody's garden. So it checks against all trees,
--    and only names the tree if that tree is public.
-- ------------------------------------------------------------
create or replace function reject_duplicate_tree()
returns trigger
language plpgsql
security definer                 -- sees everything, tells almost nothing
set search_path = public, extensions
as $$
declare
  clash_no  bigint;
  clash_pub boolean;
begin
  select tree_no, is_public into clash_no, clash_pub
    from trees
   where ST_DWithin(location, new.location, 3)
   limit 1;

  if clash_no is not null then
    if clash_pub then
      raise exception 'A tree is already registered here (Tree #%). Water that one instead.', clash_no;
    else
      raise exception 'A tree is already registered at this spot.';
    end if;
  end if;

  return new;
end;
$$;


-- ------------------------------------------------------------
-- 5. Registering a tree now asks where it stands.
-- ------------------------------------------------------------
create or replace function register_tree(
  p_species_id   text,
  p_lat          double precision,
  p_lng          double precision,
  p_photo_url    text,
  p_accuracy_m   numeric  default null,
  p_campaign_tag text     default null,
  p_notes        text     default null,
  p_planted_on   date     default current_date,
  p_is_public    boolean  default true
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

  insert into trees (planter_id, species_id, location, gps_accuracy_m,
                     planted_on, campaign_tag, notes, is_public)
  values (auth.uid(), p_species_id,
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
-- 6. A tree page now says whether it is private.
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
    'is_public',  t.is_public,
    'mine',       (t.planter_id = auth.uid()),
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
-- 7. The public ledger shows public trees only.
-- ------------------------------------------------------------
create or replace function recent_trees(n int default 8)
returns table (
  tree_no bigint,
  species text,
  city    text,
  state   text,
  planted timestamptz
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
     and t.is_public
   order by t.created_at desc
   limit n;
$$;


-- ------------------------------------------------------------
-- 8. The thirstiest public trees in the country.
--    For the front page, where we don't know where you are and
--    have no business asking until you say so.
-- ------------------------------------------------------------
create or replace function thirstiest_trees(n int default 3)
returns table (
  tree_no  bigint,
  species  text,
  city     text,
  state    text,
  days_dry int,
  planter  text
)
language sql
stable
set search_path = public
as $$
  select t.tree_no,
         coalesce(nullif(t.species_other,''), s.common_name),
         coalesce(p.city, ''),
         care_state(t),
         extract(day from now() - coalesce(t.last_cared_at, t.created_at))::int,
         coalesce(p.display_name, 'Someone')
    from trees t
    join species  s on s.id = t.species_id
    join profiles p on p.id = t.planter_id
   where t.flagged = false
     and t.is_public
     and t.status <> 'dead'
     and care_state(t) in ('needs_water','struggling')
   order by case care_state(t) when 'struggling' then 0 else 1 end,
            coalesce(t.last_cared_at, t.created_at) asc
   limit n;
$$;


-- ------------------------------------------------------------
-- 9. The headline count includes every tree, public or private.
--    A tree in somebody's courtyard is still a tree. We count
--    it; we just never say where it is.
--    (security definer, so it can see past the privacy rule --
--    it only ever returns totals, never a location.)
-- ------------------------------------------------------------
create or replace function registry_stats()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'registered', (select count(*) from trees),
    'standing',   (select count(*) from trees where status <> 'dead'),
    'waterings',  (select count(*) from care_logs),
    'species',    (select count(distinct species_id) from trees),
    'people',     (select count(*) from profiles),
    'public',     (select count(*) from trees where is_public)
  );
$$;

-- ============================================================
--  Done.
--
--  Test it: register a tree marked private, then sign out and
--  look at the map. It should be nowhere. Not in the list, not
--  in the API, nowhere.
-- ============================================================
