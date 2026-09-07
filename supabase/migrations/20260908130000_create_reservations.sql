-- Customer reservations. table_id/section_id are both nullable - a
-- reservation can be restaurant-level only, section-level, or table-level,
-- matching the existing "table layout is optional" design (sections.md /
-- ISSUES.md capacity cascade). Tables are exclusive (not communal): a table
-- hosts one confirmed reservation per time range, enforced atomically by
-- the exclusion constraint below rather than any application-level check.
--
-- btree_gist is required for the exclusion constraint - it supplies the
-- "=" operator class GiST needs for the uuid column (GiST alone only
-- understands range/geometric types).
create extension if not exists btree_gist;

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  customer_id uuid not null references auth.users (id) on delete cascade,
  section_id uuid references public.sections (id) on delete set null,
  table_id uuid references public.tables (id) on delete set null,
  party_size integer not null check (party_size > 0),
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at and ends_at <= starts_at + interval '24 hours'),
  status text not null default 'confirmed' check (status in ('confirmed', 'cancelled', 'completed', 'no_show')),
  created_at timestamptz not null default now(),
  exclude using gist (table_id with =, tstzrange(starts_at, ends_at) with &&)
    where (table_id is not null and status = 'confirmed')
);

create index reservations_restaurant_id_idx on public.reservations (restaurant_id);
create index reservations_customer_id_idx on public.reservations (customer_id);
-- The exclusion constraint's GiST index doesn't serve plain lookups/FK
-- enforcement on section_id (it isn't indexed there at all) or table_id
-- across all statuses (its GiST index has a partial predicate limited to
-- table_id is not null and status = 'confirmed') - a dedicated index on
-- each covers ON DELETE SET NULL's lookup and this migration's own
-- capacity-aggregate queries.
create index reservations_section_id_idx on public.reservations (section_id);
create index reservations_table_id_idx on public.reservations (table_id);

alter table public.reservations enable row level security;

-- Only select is granted - there is deliberately no insert/update/delete
-- grant for authenticated. Every write goes through create_reservation()
-- below (security definer, so it can write despite this), which is the one
-- place capacity/hours/table-conflict validation happens; without this, a
-- client could call .from("reservations").insert(...) directly and skip
-- all of it.
grant select on public.reservations to authenticated;

create policy "Customers can view their own reservations"
  on public.reservations for select
  to authenticated
  using (customer_id = auth.uid());

create policy "Owners can view reservations at their restaurants"
  on public.reservations for select
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );

create policy "Staff can view reservations at their restaurants"
  on public.reservations for select
  to authenticated
  using (
    exists (
      select 1 from public.restaurant_staff rs
      where rs.restaurant_id = reservations.restaurant_id
        and rs.employee_id = auth.uid()
        and rs.status = 'accepted'
    )
  );

-- Creates a reservation after validating hours, capacity, and (for a
-- specific table) seat count. security definer so it can write to
-- reservations despite the table having no insert grant for authenticated;
-- set search_path = '' (this project's standard for security-definer
-- functions, see create_profiles.sql /
-- fix_restaurant_staff_profile_policy_recursion.sql) so an authenticated
-- caller can't plant a same-named object to redirect an unqualified
-- reference - every reference in this function is schema-qualified
-- (public.xxx) or a pg_catalog builtin, which is always searched
-- regardless of search_path, so this is a pure hardening with no behavior
-- change.
--
-- Effective capacity mirrors the cascade rule already implemented
-- client-side for the owner's edit form (src/lib/capacity-cascade.ts /
-- ISSUES.md "capacity cascade"): active layouts' table seats win if any
-- layout is active, else sections' own capacity if any section exists,
-- else the restaurant's manually-set capacity (null = no limit).
--
-- Day-of-week/minute-of-day hours checks convert to 'Europe/Belgrade'
-- explicitly (the hosted database's own session timezone is UTC) - there
-- is no per-restaurant timezone column yet, so this single hardcoded zone
-- stands in for "local" everywhere in this single-locale app.
create or replace function public.create_reservation(
  p_restaurant_id uuid,
  p_party_size integer,
  p_starts_at timestamptz,
  p_stay_minutes integer default null,
  p_section_id uuid default null,
  p_table_id uuid default null
)
returns public.reservations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stay_minutes integer;
  v_ends_at timestamptz;
  v_restaurant public.restaurants;
  v_table public.tables;
  v_section_id uuid;
  v_starts_local timestamp;
  v_ends_local timestamp;
  v_start_minute integer;
  v_end_minute integer;
  v_capacity integer;
  v_booked integer;
  v_reservation public.reservations;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'customer') then
    raise exception 'Samo nalozi tipa kupac mogu praviti rezervacije.';
  end if;

  if p_party_size is null or p_party_size <= 0 then
    raise exception 'Broj gostiju mora biti veći od nule.';
  end if;

  if p_starts_at <= now() then
    raise exception 'Rezervacija mora biti u budućnosti.';
  end if;

  -- Locked unconditionally (not just in the restaurant-level branch below)
  -- so every insert against this restaurant - table-level, section-level,
  -- or restaurant-level - is serialized against every other one. Without
  -- this, a table-level booking (which takes no lock of its own, relying
  -- only on the exclusion constraint for its own table) could commit
  -- concurrently with a section- or restaurant-level capacity check that
  -- doesn't yet see it, overshooting that scope's effective capacity - the
  -- exclusion constraint only guards a single table against itself, not
  -- any aggregate.
  select * into v_restaurant from public.restaurants where id = p_restaurant_id for update;
  if not found then
    raise exception 'Restoran ne postoji.';
  end if;

  v_stay_minutes := coalesce(p_stay_minutes, v_restaurant.default_stay_minutes);
  if v_stay_minutes <= 0 then
    raise exception 'Trajanje rezervacije mora biti veće od nule.';
  end if;
  v_ends_at := p_starts_at + (v_stay_minutes || ' minutes')::interval;

  -- restaurant_hours is stored as plain local wall-clock minutes (the
  -- owner just types "09:00"), with no timezone of its own - but this
  -- database's session timezone is UTC, not Belgrade. Without converting
  -- first, extract()/::date below would silently check the wrong hour
  -- (and potentially the wrong calendar day) for this single-locale app.
  v_starts_local := p_starts_at at time zone 'Europe/Belgrade';
  v_ends_local := v_ends_at at time zone 'Europe/Belgrade';

  v_start_minute := extract(hour from v_starts_local)::int * 60 + extract(minute from v_starts_local)::int;
  v_end_minute := extract(hour from v_ends_local)::int * 60 + extract(minute from v_ends_local)::int;

  if v_ends_local::date = v_starts_local::date then
    if not exists (
      select 1 from public.restaurant_hours
      where restaurant_id = p_restaurant_id
        and day_of_week = extract(dow from v_starts_local)
        and start_minute <= v_start_minute
        and end_minute >= v_end_minute
    ) then
      raise exception 'Restoran je zatvoren u izabrano vreme.';
    end if;
  else
    -- Crosses midnight: the same split-at-midnight representation the
    -- owner-side calendar already produces (start's day reaching to 1440,
    -- the next day_of_week starting at 0) must cover both halves.
    if not exists (
      select 1 from public.restaurant_hours
      where restaurant_id = p_restaurant_id
        and day_of_week = extract(dow from v_starts_local)
        and start_minute <= v_start_minute
        and end_minute = 1440
    ) or not exists (
      select 1 from public.restaurant_hours
      where restaurant_id = p_restaurant_id
        and day_of_week = mod(extract(dow from v_starts_local)::int + 1, 7)
        and start_minute = 0
        and end_minute >= v_end_minute
    ) then
      raise exception 'Restoran je zatvoren u izabrano vreme.';
    end if;
  end if;

  if p_table_id is not null then
    select * into v_table from public.tables where id = p_table_id and restaurant_id = p_restaurant_id;
    if not found then
      raise exception 'Sto ne postoji u ovom restoranu.';
    end if;
    -- Only a table on a currently-active layout is actually "in service" -
    -- see the layouts table's own comment (only active layouts drive
    -- capacity and what customers see).
    if not exists (select 1 from public.layouts where id = v_table.layout_id and is_active) then
      raise exception 'Sto nije deo trenutno aktivnog rasporeda.';
    end if;
    if p_party_size > v_table.seats then
      raise exception 'Sto ne može da primi toliko gostiju.';
    end if;
    v_section_id := v_table.section_id;
    -- No capacity aggregate check needed here - the exclusion constraint
    -- below is the enforcement for a specific table. But if the table
    -- belongs to a section, that section's own row still needs locking
    -- (the restaurant row is already locked above) so a concurrent
    -- section-level booking's aggregate check is serialized against this
    -- insert instead of racing it.
    if v_section_id is not null then
      perform 1 from public.sections where id = v_section_id for update;
    end if;

  elsif p_section_id is not null then
    if not exists (select 1 from public.sections where id = p_section_id and restaurant_id = p_restaurant_id) then
      raise exception 'Sekcija ne postoji u ovom restoranu.';
    end if;
    v_section_id := p_section_id;

    -- Lock the section row (in addition to the restaurant row already
    -- locked above) so two concurrent bookings against it can't both read
    -- the same "booked so far" total before either commits.
    perform 1 from public.sections where id = v_section_id for update;

    if exists (select 1 from public.layouts where restaurant_id = p_restaurant_id and is_active) then
      select coalesce(sum(t.seats), 0) into v_capacity
      from public.tables t
      join public.layouts l on l.id = t.layout_id
      where l.restaurant_id = p_restaurant_id and l.is_active and t.section_id = v_section_id;
    else
      select capacity into v_capacity from public.sections where id = v_section_id;
    end if;

    -- Every confirmed reservation tagged to this section counts against
    -- its capacity, whether or not that reservation also has its own
    -- table_id - a table-level booking still consumes section capacity.
    select coalesce(sum(party_size), 0) into v_booked
    from public.reservations
    where section_id = v_section_id
      and status = 'confirmed'
      and tstzrange(starts_at, ends_at) && tstzrange(p_starts_at, v_ends_at);

    if v_booked + p_party_size > v_capacity then
      raise exception 'Nema dovoljno slobodnih mesta u izabrano vreme.';
    end if;

  else
    -- Restaurant row is already locked above (unconditionally) - nothing
    -- extra to lock here.
    if exists (select 1 from public.layouts where restaurant_id = p_restaurant_id and is_active) then
      select coalesce(sum(t.seats), 0) into v_capacity
      from public.tables t
      join public.layouts l on l.id = t.layout_id
      where l.restaurant_id = p_restaurant_id and l.is_active;
    elsif exists (select 1 from public.sections where restaurant_id = p_restaurant_id) then
      select coalesce(sum(capacity), 0) into v_capacity
      from public.sections where restaurant_id = p_restaurant_id;
    else
      v_capacity := v_restaurant.capacity;
    end if;

    if v_capacity is not null then
      -- Every confirmed reservation anywhere in the restaurant counts here
      -- - restaurant capacity is the outer ceiling every section/table
      -- booking also draws from.
      select coalesce(sum(party_size), 0) into v_booked
      from public.reservations
      where restaurant_id = p_restaurant_id
        and status = 'confirmed'
        and tstzrange(starts_at, ends_at) && tstzrange(p_starts_at, v_ends_at);

      if v_booked + p_party_size > v_capacity then
        raise exception 'Nema dovoljno slobodnih mesta u izabrano vreme.';
      end if;
    end if;
  end if;

  insert into public.reservations
    (restaurant_id, customer_id, section_id, table_id, party_size, starts_at, ends_at, status)
  values
    (p_restaurant_id, auth.uid(), v_section_id, p_table_id, p_party_size, p_starts_at, v_ends_at, 'confirmed')
  returning * into v_reservation;

  return v_reservation;
exception
  when exclusion_violation then
    raise exception 'Sto je već rezervisan u to vreme.';
end;
$$;

grant execute on function public.create_reservation(uuid, integer, timestamptz, integer, uuid, uuid) to authenticated;
