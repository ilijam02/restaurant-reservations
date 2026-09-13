-- Closes a gap found while reviewing the customer reservations list: nothing
-- stopped an owner from deleting a table/section (or reducing
-- restaurants.capacity/sections.capacity) out from under a confirmed,
-- not-yet-ended reservation. reservation_tables.table_id and
-- reservation_sections.section_id are both "on delete cascade" (see
-- create_reservations.sql), so a table/section delete silently wiped the
-- seating record - the parent reservations row survived with status still
-- 'confirmed' but zero reservation_tables/reservation_sections rows, showing
-- up to the customer as a confirmed booking with no table/section info and
-- no indication anything went wrong. A capacity decrease had no protection
-- at all - restaurants.capacity/sections.capacity could be dropped below
-- what's already promised to confirmed reservations with no check whatsoever.
--
-- "Active" here matches the exact same time-based rule the customer
-- reservations page uses (see customer-reservations-list.tsx): status =
-- 'confirmed' and ends_at >= now(). A reservation that's already
-- ended/cancelled/completed/no-show never blocks anything.
--
-- The capacity checks are the harder half: a single reservation's party_size
-- alone isn't enough, since several confirmed reservations can overlap in
-- time and their party sizes must be summed at the moment they overlap, not
-- just individually compared against the new capacity. Both
-- *_peak_reserved_capacity() functions below compute that via a standard
-- sweep-line: turn every relevant reservation's [starts_at, ends_at) range
-- into a +party_size event at starts_at and a -party_size event at ends_at,
-- then take the maximum running sum over those events in time order. Ties at
-- the same instant are ordered "leaves" (negative delta) before "arrives"
-- (positive delta) by sorting on (t, delta), matching the half-open `[)`
-- convention already used by reservation_tables' exclusion constraint - a
-- reservation ending at T does not overlap one starting at T.
--
-- security definer + set search_path = '' throughout, per this project's
-- standing convention (see create_reservation()'s comment block) - not
-- strictly required here since triggers don't need an explicit execute grant
-- and the owner already has RLS select access to everything these functions
-- read, but kept consistent with every other function in this codebase.

create or replace function public.restaurant_peak_reserved_capacity(p_restaurant_id uuid)
returns integer
language sql
security definer
set search_path = ''
stable
as $$
  with events as (
    select starts_at as t, party_size as delta
    from public.reservations
    where restaurant_id = p_restaurant_id
      and status = 'confirmed'
      and ends_at >= now()
    union all
    select ends_at as t, -party_size as delta
    from public.reservations
    where restaurant_id = p_restaurant_id
      and status = 'confirmed'
      and ends_at >= now()
  ),
  running as (
    select sum(delta) over (order by t, delta rows between unbounded preceding and current row) as concurrent_total
    from events
  )
  select coalesce(max(concurrent_total), 0) from running;
$$;

create or replace function public.section_peak_reserved_capacity(p_section_id uuid)
returns integer
language sql
security definer
set search_path = ''
stable
as $$
  with events as (
    select r.starts_at as t, rs.party_size as delta
    from public.reservation_sections rs
    join public.reservations r on r.id = rs.reservation_id
    where rs.section_id = p_section_id
      and r.status = 'confirmed'
      and r.ends_at >= now()
    union all
    select r.ends_at as t, -rs.party_size as delta
    from public.reservation_sections rs
    join public.reservations r on r.id = rs.reservation_id
    where rs.section_id = p_section_id
      and r.status = 'confirmed'
      and r.ends_at >= now()
  ),
  running as (
    select sum(delta) over (order by t, delta rows between unbounded preceding and current row) as concurrent_total
    from events
  )
  select coalesce(max(concurrent_total), 0) from running;
$$;

create or replace function public.prevent_table_delete_with_active_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.reservation_tables rt
    join public.reservations r on r.id = rt.reservation_id
    where rt.table_id = old.id
      and r.status = 'confirmed'
      and r.ends_at >= now()
  ) then
    raise exception 'Sto ima aktivnu rezervaciju i ne može biti obrisan.';
  end if;
  return old;
end;
$$;

create trigger tables_prevent_delete_with_active_reservation
  before delete on public.tables
  for each row
  execute function public.prevent_table_delete_with_active_reservation();

create or replace function public.prevent_section_delete_with_active_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.reservation_sections rs
    join public.reservations r on r.id = rs.reservation_id
    where rs.section_id = old.id
      and r.status = 'confirmed'
      and r.ends_at >= now()
  ) then
    raise exception 'Sekcija ima aktivnu rezervaciju i ne može biti obrisana.';
  end if;
  return old;
end;
$$;

create trigger sections_prevent_delete_with_active_reservation
  before delete on public.sections
  for each row
  execute function public.prevent_section_delete_with_active_reservation();

-- Fires on every capacity write, not just decreases - an increase or a
-- switch to null (unlimited) can never trip the check, so there's no need to
-- special-case direction; simpler to always compare than to compute
-- old-vs-new sign first.
create or replace function public.prevent_restaurant_capacity_below_reserved()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_peak integer;
begin
  if new.capacity is not null then
    v_peak := public.restaurant_peak_reserved_capacity(new.id);
    if new.capacity < v_peak then
      raise exception 'Kapacitet ne može biti manji od % - toliko gostiju već ima potvrđenu rezervaciju u istom terminu.', v_peak;
    end if;
  end if;
  return new;
end;
$$;

create trigger restaurants_prevent_capacity_below_reserved
  before update on public.restaurants
  for each row
  when (new.capacity is distinct from old.capacity)
  execute function public.prevent_restaurant_capacity_below_reserved();

-- sections.capacity has no "unlimited" (null) option - always checked.
create or replace function public.prevent_section_capacity_below_reserved()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_peak integer;
begin
  v_peak := public.section_peak_reserved_capacity(new.id);
  if new.capacity < v_peak then
    raise exception 'Kapacitet sekcije ne može biti manji od % - toliko gostiju već ima potvrđenu rezervaciju u istom terminu.', v_peak;
  end if;
  return new;
end;
$$;

create trigger sections_prevent_capacity_below_reserved
  before update on public.sections
  for each row
  when (new.capacity is distinct from old.capacity)
  execute function public.prevent_section_capacity_below_reserved();
