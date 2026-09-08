-- Customer reservations. Where a reservation is actually seated lives
-- entirely in the two child tables below (reservation_tables /
-- reservation_sections), used mutually exclusively per reservation, and
-- neither when the restaurant has no layout and no sections (the plain
-- restaurant-capacity baseline case). A single nullable table_id/section_id
-- column here wouldn't generalize: a reservation can span multiple tables
-- (customer picks several, or the system auto-assigns several to cover one
-- party) or multiple sections (auto-split when no single section has
-- enough room), so both need their own party-size-bearing join tables.
--
-- btree_gist is required for reservation_tables' exclusion constraint - it
-- supplies the "=" operator class GiST needs for the uuid column (GiST
-- alone only understands range/geometric types).
create extension if not exists btree_gist;

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  customer_id uuid not null references auth.users (id) on delete cascade,
  party_size integer not null check (party_size > 0),
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at and ends_at <= starts_at + interval '24 hours'),
  status text not null default 'confirmed' check (status in ('confirmed', 'cancelled', 'completed', 'no_show')),
  created_at timestamptz not null default now()
);

create index reservations_restaurant_id_idx on public.reservations (restaurant_id);
create index reservations_customer_id_idx on public.reservations (customer_id);

alter table public.reservations enable row level security;

-- Only select is granted - there is deliberately no insert/update/delete
-- grant for authenticated. Every write goes through create_reservation()
-- below (security definer, so it can write despite this), which is the one
-- place hours/capacity/table-conflict validation happens; without this, a
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

-- One row per table a reservation occupies (several for a multi-table
-- booking). Tables are exclusive (not communal): a table hosts one
-- confirmed reservation per time range, enforced atomically by the
-- exclusion constraint rather than any application-level check.
-- starts_at/ends_at are denormalized copies of the parent reservation's
-- range - an exclusion constraint has to reference columns on the same
-- row as what it's guarding, so the range has to live here too, not just
-- on reservations.
create table public.reservation_tables (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations (id) on delete cascade,
  table_id uuid not null references public.tables (id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  unique (reservation_id, table_id),
  -- Not status-aware (unlike the app-level overlap checks in
  -- create_reservation(), which do filter on status = 'confirmed') - every
  -- reservation is 'confirmed' at insert today and nothing sets
  -- 'cancelled' yet, so this is harmless for now. Once cancellation ships,
  -- a cancelled reservation's row here would permanently block that
  -- table/time slot unless cancelling also deletes (or this constraint
  -- gains a matching status column + partial predicate) its
  -- reservation_tables rows.
  exclude using gist (table_id with =, tstzrange(starts_at, ends_at) with &&)
);

create index reservation_tables_reservation_id_idx on public.reservation_tables (reservation_id);
create index reservation_tables_table_id_idx on public.reservation_tables (table_id);

alter table public.reservation_tables enable row level security;

grant select on public.reservation_tables to authenticated;

create policy "Customers can view their own reservation tables"
  on public.reservation_tables for select
  to authenticated
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id and r.customer_id = auth.uid()
    )
  );

create policy "Owners can view reservation tables at their restaurants"
  on public.reservation_tables for select
  to authenticated
  using (
    exists (
      select 1 from public.reservations r
      join public.restaurants res on res.id = r.restaurant_id
      where r.id = reservation_id and res.owner_id = auth.uid()
    )
  );

create policy "Staff can view reservation tables at their restaurants"
  on public.reservation_tables for select
  to authenticated
  using (
    exists (
      select 1 from public.reservations r
      join public.restaurant_staff rs on rs.restaurant_id = r.restaurant_id
      where r.id = reservation_id and rs.employee_id = auth.uid() and rs.status = 'accepted'
    )
  );

-- One row per section a reservation draws capacity from, only used when a
-- restaurant has sections but no active layout (once a layout is active,
-- sections are just a tag on tables - see the capacity-cascade rule in
-- ISSUES.md - and reservation_tables above is what's used instead).
-- party_size is the portion of the reservation's total party allocated to
-- *this* section; several rows can belong to one reservation (an
-- auto-split across sections when no single one has enough room), summing
-- to the parent reservation's party_size.
create table public.reservation_sections (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations (id) on delete cascade,
  section_id uuid not null references public.sections (id) on delete cascade,
  party_size integer not null check (party_size > 0),
  unique (reservation_id, section_id)
);

create index reservation_sections_reservation_id_idx on public.reservation_sections (reservation_id);
create index reservation_sections_section_id_idx on public.reservation_sections (section_id);

alter table public.reservation_sections enable row level security;

grant select on public.reservation_sections to authenticated;

create policy "Customers can view their own reservation sections"
  on public.reservation_sections for select
  to authenticated
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id and r.customer_id = auth.uid()
    )
  );

create policy "Owners can view reservation sections at their restaurants"
  on public.reservation_sections for select
  to authenticated
  using (
    exists (
      select 1 from public.reservations r
      join public.restaurants res on res.id = r.restaurant_id
      where r.id = reservation_id and res.owner_id = auth.uid()
    )
  );

create policy "Staff can view reservation sections at their restaurants"
  on public.reservation_sections for select
  to authenticated
  using (
    exists (
      select 1 from public.reservations r
      join public.restaurant_staff rs on rs.restaurant_id = r.restaurant_id
      where r.id = reservation_id and rs.employee_id = auth.uid() and rs.status = 'accepted'
    )
  );

-- Creates a reservation after validating hours, duration, and capacity,
-- assigning actual table(s)/section(s) along the way. security definer so
-- it can write despite none of the three tables above granting
-- insert/update/delete to authenticated; set search_path = '' (this
-- project's standard for security-definer functions, see
-- create_profiles.sql / fix_restaurant_staff_profile_policy_recursion.sql)
-- since every reference here is schema-qualified (public.xxx) or a
-- pg_catalog builtin (always searched regardless of search_path).
--
-- p_table_ids is the one thing validated strictly against exactly what was
-- chosen (rejected if it doesn't fit - no silent expansion into tables the
-- customer didn't ask for). p_section_id, by contrast, is only ever a
-- *preference* for where to start - if it can't fit the whole party alone,
-- the remainder spills into other tables/sections rather than being
-- rejected outright:
--   - p_table_ids given: exact tables, party must fit their combined seats.
--   - no p_table_ids, an active layout exists: auto-assign free tables,
--     preferring p_section_id's tables first (if given) then the rest of
--     the restaurant, largest-seat-first, until the party is covered.
--   - no p_table_ids, no active layout, sections exist: auto-assign across
--     sections, preferring p_section_id first (if given) then the rest by
--     remaining capacity (most room first), splitting across as many as it
--     takes to cover the party.
--   - no layout, no sections at all: plain restaurant.capacity ceiling
--     (null = unlimited), unchanged from the original design.
-- Once a layout is active or sections exist, that becomes the entire
-- capacity story (matching the capacity-cascade rule already established
-- for the owner's edit form) - restaurants.capacity is only ever consulted
-- in the last, simplest case.
--
-- Every "not enough room" rejection reports how much room actually is
-- available at that time, so the customer isn't left guessing how far off
-- they were.
--
-- Concurrency: the restaurant row is locked unconditionally near the top,
-- which serializes *every* insert against a given restaurant - table-level,
-- section-level, or restaurant-level - against every other one, so the
-- "how much room is left" reads throughout this function can't race a
-- concurrent booking on the same restaurant. Every branch computes its
-- assignment plan read-only first and only inserts once that plan is
-- confirmed to cover the whole party, so a rejected attempt never leaves a
-- partial reservation behind.
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
  p_table_ids uuid[] default null
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
  v_starts_local timestamp;
  v_ends_local timestamp;
  v_start_date date;
  v_open tsmultirange;
  v_capacity integer;
  v_booked integer;
  v_reservation_id uuid;
  v_reservation public.reservations;
  v_running integer;
  v_remaining integer;
  v_alloc integer;
  v_chosen_table_ids uuid[];
  v_chosen_section_ids uuid[];
  v_chosen_section_allocs integer[];
  r record;
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

  -- Locked unconditionally (not just for a restaurant-level booking) so
  -- every insert against this restaurant is serialized against every
  -- other one - see the concurrency note above.
  select * into v_restaurant from public.restaurants where id = p_restaurant_id for update;
  if not found then
    raise exception 'Restoran ne postoji.';
  end if;

  v_stay_minutes := coalesce(p_stay_minutes, v_restaurant.default_stay_minutes);
  if v_stay_minutes < 30 then
    raise exception 'Rezervacija mora trajati bar 30 minuta.';
  end if;
  if v_stay_minutes > 180 then
    raise exception 'Rezervacija ne može trajati duže od 3 sata.';
  end if;
  v_ends_at := p_starts_at + (v_stay_minutes || ' minutes')::interval;

  -- restaurant_hours is stored as plain local wall-clock minutes (the
  -- owner just types "09:00"), with no timezone of its own - but this
  -- database's session timezone is UTC, not Belgrade. Without converting
  -- first, extract()/::date below would silently check the wrong hour
  -- (and potentially the wrong calendar day) for this single-locale app.
  v_starts_local := p_starts_at at time zone 'Europe/Belgrade';
  v_ends_local := v_ends_at at time zone 'Europe/Belgrade';
  v_start_date := v_starts_local::date;

  -- Built as a multirange, anchored to real calendar timestamps, rather
  -- than checking whether a single restaurant_hours row contains the whole
  -- reservation - a multirange automatically merges touching/overlapping
  -- segments (range_agg()'s normalization), so two back-to-back blocks
  -- like "05:00-05:30" and "05:30-07:00" (or an overnight block split
  -- across two day_of_week rows at the 1440/0 boundary) are correctly
  -- treated as one continuous open period. A reservation spanning across
  -- such a seam was previously rejected, since neither row alone contained
  -- it. Only the start day and the day after can matter, since a
  -- reservation is at most 3 hours (the duration cap enforced above).
  select range_agg(seg) into v_open
  from (
    select tsrange(
      d.day_date + (rh.start_minute || ' minutes')::interval,
      case when rh.end_minute = 1440 then d.day_date + interval '1 day'
           else d.day_date + (rh.end_minute || ' minutes')::interval end,
      '[)'
    ) as seg
    from (
      values (v_start_date, extract(dow from v_start_date)::int),
             (v_start_date + 1, mod(extract(dow from v_start_date)::int + 1, 7))
    ) as d(day_date, dow)
    join public.restaurant_hours rh on rh.restaurant_id = p_restaurant_id and rh.day_of_week = d.dow
  ) segs;

  if v_open is null or not (tsrange(v_starts_local, v_ends_local, '[)') <@ v_open) then
    raise exception 'Restoran je zatvoren u izabrano vreme.';
  end if;

  if p_table_ids is not null and cardinality(p_table_ids) > 0 then
    -- Explicit tables: validated strictly, no auto-expansion.
    if cardinality(p_table_ids) <> cardinality(array(select distinct unnest(p_table_ids))) then
      raise exception 'Isti sto je izabran više puta.';
    end if;

    if exists (
      select 1 from unnest(p_table_ids) as tid
      where not exists (
        select 1 from public.tables t
        join public.layouts l on l.id = t.layout_id
        where t.id = tid and t.restaurant_id = p_restaurant_id and l.is_active
      )
    ) then
      raise exception 'Sto ne postoji u ovom restoranu ili nije deo aktivnog rasporeda.';
    end if;

    select coalesce(sum(seats), 0) into v_capacity from public.tables where id = any(p_table_ids);
    if p_party_size > v_capacity then
      raise exception 'Izabrani stolovi ne mogu da prime toliko gostiju.';
    end if;

    insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
    values (p_restaurant_id, auth.uid(), p_party_size, p_starts_at, v_ends_at, 'confirmed')
    returning id into v_reservation_id;

    insert into public.reservation_tables (reservation_id, table_id, starts_at, ends_at)
    select v_reservation_id, tid, p_starts_at, v_ends_at from unnest(p_table_ids) as tid;

  elsif exists (select 1 from public.layouts where restaurant_id = p_restaurant_id and is_active) then
    -- No table chosen but a layout is active: auto-assign free tables,
    -- preferring p_section_id's (if given) then the rest of the
    -- restaurant, largest-seat-first, until the party is covered.
    v_running := 0;
    v_chosen_table_ids := '{}';
    for r in (
      select t.id, t.seats
      from public.tables t
      join public.layouts l on l.id = t.layout_id
      where l.restaurant_id = p_restaurant_id
        and l.is_active
        and not exists (
          select 1 from public.reservation_tables rt
          join public.reservations res on res.id = rt.reservation_id
          where rt.table_id = t.id
            and res.status = 'confirmed'
            and tstzrange(rt.starts_at, rt.ends_at) && tstzrange(p_starts_at, v_ends_at)
        )
      order by (t.section_id = p_section_id) desc nulls last, t.seats desc
    )
    loop
      exit when v_running >= p_party_size;
      v_chosen_table_ids := array_append(v_chosen_table_ids, r.id);
      v_running := v_running + r.seats;
    end loop;

    if v_running < p_party_size then
      raise exception 'Nema dovoljno slobodnih mesta u izabrano vreme (slobodno mesta: %).', v_running;
    end if;

    insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
    values (p_restaurant_id, auth.uid(), p_party_size, p_starts_at, v_ends_at, 'confirmed')
    returning id into v_reservation_id;

    insert into public.reservation_tables (reservation_id, table_id, starts_at, ends_at)
    select v_reservation_id, tid, p_starts_at, v_ends_at from unnest(v_chosen_table_ids) as tid;

  elsif exists (select 1 from public.sections where restaurant_id = p_restaurant_id) then
    -- No layout, sections exist: auto-split across sections, preferring
    -- p_section_id first (if given) then the rest by remaining capacity,
    -- most room first - same "preference, not a hard requirement"
    -- treatment the table auto-assign branch above gives p_section_id, so
    -- a preferred section that can't fit the whole party spills into
    -- others rather than being rejected outright.
    v_remaining := p_party_size;
    v_chosen_section_ids := '{}';
    v_chosen_section_allocs := '{}';
    for r in (
      select s.id,
        s.capacity - coalesce((
          select sum(rs.party_size) from public.reservation_sections rs
          join public.reservations res on res.id = rs.reservation_id
          where rs.section_id = s.id
            and res.status = 'confirmed'
            and tstzrange(res.starts_at, res.ends_at) && tstzrange(p_starts_at, v_ends_at)
        ), 0) as remaining
      from public.sections s
      where s.restaurant_id = p_restaurant_id
      order by (s.id = p_section_id) desc nulls last, remaining desc
    )
    loop
      exit when v_remaining <= 0;
      continue when r.remaining <= 0;
      v_alloc := least(v_remaining, r.remaining);
      v_chosen_section_ids := array_append(v_chosen_section_ids, r.id);
      v_chosen_section_allocs := array_append(v_chosen_section_allocs, v_alloc);
      v_remaining := v_remaining - v_alloc;
    end loop;

    if v_remaining > 0 then
      raise exception 'Nema dovoljno slobodnih mesta u izabrano vreme (slobodno mesta: %).', (p_party_size - v_remaining);
    end if;

    insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
    values (p_restaurant_id, auth.uid(), p_party_size, p_starts_at, v_ends_at, 'confirmed')
    returning id into v_reservation_id;

    insert into public.reservation_sections (reservation_id, section_id, party_size)
    select v_reservation_id, sid, alloc
    from unnest(v_chosen_section_ids, v_chosen_section_allocs) as u(sid, alloc);

  else
    -- No layout, no sections at all: the original, simplest baseline.
    v_capacity := v_restaurant.capacity;
    if v_capacity is not null then
      select coalesce(sum(party_size), 0) into v_booked
      from public.reservations
      where restaurant_id = p_restaurant_id
        and status = 'confirmed'
        and tstzrange(starts_at, ends_at) && tstzrange(p_starts_at, v_ends_at);

      if v_booked + p_party_size > v_capacity then
        raise exception 'Nema dovoljno slobodnih mesta u izabrano vreme (slobodno mesta: %).', (v_capacity - v_booked);
      end if;
    end if;

    insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
    values (p_restaurant_id, auth.uid(), p_party_size, p_starts_at, v_ends_at, 'confirmed')
    returning id into v_reservation_id;
  end if;

  select * into v_reservation from public.reservations where id = v_reservation_id;
  return v_reservation;
exception
  when exclusion_violation then
    raise exception 'Sto je već rezervisan u to vreme.';
end;
$$;

grant execute on function public.create_reservation(uuid, integer, timestamptz, integer, uuid, uuid[]) to authenticated;
