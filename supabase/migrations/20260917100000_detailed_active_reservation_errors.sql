-- Follow-up to 20260913140000_protect_capacity_from_active_reservations.sql:
-- "Sto ima aktivnu rezervaciju i ne može biti obrisan." doesn't tell the
-- owner WHICH table, or which reservation is the actual problem - annoying
-- when saving a batch of changes at once (the owner's edit form can remove
-- several tables/sections in one "Sačuvaj izmene"), since the trigger only
-- reports the first blocking row it happens to hit and the owner has to
-- retry repeatedly to discover the rest one at a time.
--
-- Two changes:
-- 1. The existing delete-blocking triggers now name the specific
--    table/section and its earliest active reservation's date/time and
--    party size directly in the raised message - still only reports one
--    row (a trigger fires and aborts per row), but that one row is now
--    fully explained. This remains the authoritative, last-resort DB-level
--    enforcement regardless of how the delete was attempted.
-- 2. Two new read-only functions let the owner's edit form check every
--    candidate table/section id *before* attempting any delete, so a single
--    save reports every blocking table/section (with its own earliest
--    active reservation) in one message instead of failing one at a time.
--    Granted execute to authenticated, unlike this migration's other
--    functions, since these are meant to be called directly via
--    `supabase.rpc(...)` - same treatment as get_occupied_table_ids() /
--    get_section_remaining_capacity(), which are also plain availability
--    lookups open to any authenticated caller without an ownership check
--    (tables/sections are already public-read, so this reveals nothing
--    that couldn't already be inferred).

create or replace function public.tables_with_active_reservations(p_table_ids uuid[])
returns table (table_id uuid, table_name text, starts_at timestamptz, party_size integer)
language sql
security definer
set search_path = ''
stable
as $$
  select distinct on (t.id) t.id, t.name, r.starts_at, r.party_size
  from public.tables t
  join public.reservation_tables rt on rt.table_id = t.id
  join public.reservations r on r.id = rt.reservation_id
  where t.id = any(p_table_ids)
    and r.status = 'confirmed'
    and r.ends_at >= now()
  order by t.id, r.starts_at;
$$;

grant execute on function public.tables_with_active_reservations(uuid[]) to authenticated;

create or replace function public.sections_with_active_reservations(p_section_ids uuid[])
returns table (section_id uuid, section_name text, starts_at timestamptz, party_size integer)
language sql
security definer
set search_path = ''
stable
as $$
  select distinct on (s.id) s.id, s.name, r.starts_at, rs.party_size
  from public.sections s
  join public.reservation_sections rs on rs.section_id = s.id
  join public.reservations r on r.id = rs.reservation_id
  where s.id = any(p_section_ids)
    and r.status = 'confirmed'
    and r.ends_at >= now()
  order by s.id, r.starts_at;
$$;

grant execute on function public.sections_with_active_reservations(uuid[]) to authenticated;

create or replace function public.prevent_table_delete_with_active_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_starts_at timestamptz;
  v_party_size integer;
begin
  select r.starts_at, r.party_size into v_starts_at, v_party_size
  from public.reservation_tables rt
  join public.reservations r on r.id = rt.reservation_id
  where rt.table_id = old.id
    and r.status = 'confirmed'
    and r.ends_at >= now()
  order by r.starts_at
  limit 1;

  if v_starts_at is not null then
    raise exception 'Sto "%" ima aktivnu rezervaciju za % (% gostiju) i ne može biti obrisan.',
      old.name,
      to_char(v_starts_at at time zone 'Europe/Belgrade', 'DD.MM.YYYY HH24:MI'),
      v_party_size;
  end if;
  return old;
end;
$$;

create or replace function public.prevent_section_delete_with_active_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_starts_at timestamptz;
  v_party_size integer;
begin
  select r.starts_at, rs.party_size into v_starts_at, v_party_size
  from public.reservation_sections rs
  join public.reservations r on r.id = rs.reservation_id
  where rs.section_id = old.id
    and r.status = 'confirmed'
    and r.ends_at >= now()
  order by r.starts_at
  limit 1;

  if v_starts_at is not null then
    raise exception 'Sekcija "%" ima aktivnu rezervaciju za % (% gostiju) i ne može biti obrisana.',
      old.name,
      to_char(v_starts_at at time zone 'Europe/Belgrade', 'DD.MM.YYYY HH24:MI'),
      v_party_size;
  end if;
  return old;
end;
$$;
