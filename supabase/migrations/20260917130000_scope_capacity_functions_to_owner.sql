-- Code review finding: tables_with_active_reservations(), sections_with_active_reservations()
-- and sections_peak_reserved_capacity() (20260917100000_detailed_active_reservation_errors.sql,
-- 20260917120000_sections_peak_reserved_capacity_batch.sql) are security definer,
-- granted to authenticated, and performed no ownership check - since
-- tables/sections are public-read (their ids are freely enumerable by any
-- logged-in customer or employee), any authenticated user could pass an
-- arbitrary table/section id from ANY restaurant and learn another
-- customer's reservation time and party size, bypassing the RLS that
-- otherwise restricts reservations/reservation_tables/reservation_sections
-- to the customer who owns the booking, the restaurant's owner, and its
-- accepted staff. get_occupied_table_ids()/get_section_remaining_capacity()
-- (20260908150000/20260908160000) are deliberately open to any authenticated
-- user, but only ever reveal an occupied/remaining-capacity *signal*, never
-- a specific reservation's time or party size - these three functions broke
-- that boundary.
--
-- Fix: same signatures and column lists (no drop needed), each now joins up
-- to restaurants and requires res.owner_id = auth.uid() - matching the
-- ownership check every other owner-write RLS policy in this schema already
-- uses (see tables'/sections' own delete policies). These functions are
-- only ever called from the owner's edit form for restaurants that owner
-- already owns, so this changes nothing for legitimate use - a table/section
-- id belonging to someone else's restaurant now simply doesn't appear in
-- the result, instead of leaking its reservation.
create or replace function public.tables_with_active_reservations(p_table_ids uuid[])
returns table (table_id uuid, table_name text, layout_name text, starts_at timestamptz, party_size integer)
language sql
security definer
set search_path = ''
stable
as $$
  select distinct on (t.id) t.id, t.name, l.name, r.starts_at, r.party_size
  from public.tables t
  join public.layouts l on l.id = t.layout_id
  join public.restaurants res on res.id = t.restaurant_id
  join public.reservation_tables rt on rt.table_id = t.id
  join public.reservations r on r.id = rt.reservation_id
  where t.id = any(p_table_ids)
    and res.owner_id = auth.uid()
    and r.status = 'confirmed'
    and r.ends_at >= now()
  order by t.id, r.starts_at;
$$;

create or replace function public.sections_with_active_reservations(p_section_ids uuid[])
returns table (section_id uuid, section_name text, starts_at timestamptz, party_size integer)
language sql
security definer
set search_path = ''
stable
as $$
  select distinct on (s.id) s.id, s.name, r.starts_at, rs.party_size
  from public.sections s
  join public.restaurants res on res.id = s.restaurant_id
  join public.reservation_sections rs on rs.section_id = s.id
  join public.reservations r on r.id = rs.reservation_id
  where s.id = any(p_section_ids)
    and res.owner_id = auth.uid()
    and r.status = 'confirmed'
    and r.ends_at >= now()
  order by s.id, r.starts_at;
$$;

create or replace function public.sections_peak_reserved_capacity(p_section_ids uuid[])
returns table (section_id uuid, section_name text, peak_capacity integer)
language sql
security definer
set search_path = ''
stable
as $$
  select s.id, s.name, public.section_peak_reserved_capacity(s.id)
  from public.sections s
  join public.restaurants res on res.id = s.restaurant_id
  where s.id = any(p_section_ids)
    and res.owner_id = auth.uid();
$$;
