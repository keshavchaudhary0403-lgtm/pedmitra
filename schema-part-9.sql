-- ============================================================
--  PedMitra — part 9 (combined)
--
--  Three things, all about one question: how close is "the same
--  tree" versus "two real trees next to each other"?
--
--   1. The planter (and only the planter) can change a tree
--      between public and private.
--   2. A clear message when a private->public flip collides.
--   3. The duplicate radius drops from 3 m to 1 m -- because a
--      real garden or avenue plants trees a metre or two apart,
--      and the old rule wrongly rejected the second and third.
--
--  Why 1 metre: it still catches a true duplicate (the same
--  trunk photographed twice -- phone GPS can't tell two points
--  30 cm apart anyway), while letting a genuine row of saplings
--  through. Home trees are never checked at all; a balcony holds
--  many pots within arm's reach.
--
--  Run AFTER parts 1-8. If you already ran an earlier part 9,
--  running this again is fine -- it just replaces the functions.
-- ============================================================

set search_path = public, extensions;


-- ------------------------------------------------------------
-- Register a tree. Duplicate check first, at 1 metre, before a
-- number is ever drawn.
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
  new_id   uuid;
  new_no   bigint;
  clash_no bigint;
  here     geography := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in first.';
  end if;

  -- Only public trees are checked, and only against other public
  -- trees, at 1 metre. A real second tree stands more than a metre
  -- from the first; only a duplicate of the SAME trunk lands inside.
  if coalesce(p_is_public, true) then
    select tree_no into clash_no
      from trees
     where is_public = true
       and ST_DWithin(location, here, 1)
     limit 1;

    if clash_no is not null then
      raise exception 'This looks like Tree #% — it is already registered right here. If it is a different tree, take a step to it and try again.', clash_no;
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


-- ------------------------------------------------------------
-- Change a tree between public and private. Planter only.
-- ------------------------------------------------------------
create or replace function set_tree_privacy(p_tree_no bigint, p_is_public boolean)
returns json
language plpgsql
set search_path = public, extensions
as $$
declare
  t        trees%rowtype;
  clash_no bigint;
begin
  if auth.uid() is null then
    raise exception 'You need to sign in first.';
  end if;

  select * into t from trees where tree_no = p_tree_no;
  if t.id is null then
    raise exception 'No tree with that number.';
  end if;

  -- Only the planter. No admin path, on purpose.
  if t.planter_id <> auth.uid() then
    raise exception 'Only the person who planted this tree can change it.';
  end if;

  if t.is_public = p_is_public then
    return json_build_object('tree_no', p_tree_no, 'is_public', t.is_public);
  end if;

  -- Revealing a hidden tree must pass the same 1-metre check a new
  -- public tree would. Hiding a tree never needs a check.
  if p_is_public = true then
    select tree_no into clash_no
      from trees
     where is_public = true
       and id <> t.id
       and ST_DWithin(location, t.location, 1)
     limit 1;

    if clash_no is not null then
      raise exception 'There is already a public tree at this exact spot (Tree #%). Two public trees can''t share one location, so this one stays private. If it really is a separate tree, its pin needs to be a step away.', clash_no;
    end if;
  end if;

  update trees set is_public = p_is_public where id = t.id;

  return json_build_object('tree_no', p_tree_no, 'is_public', p_is_public);
end;
$$;

-- ============================================================
--  Done.
--
--  Now a row of trees a metre or two apart all register fine.
--  Only a second attempt on the SAME spot -- within a metre --
--  is treated as a duplicate.
-- ============================================================
