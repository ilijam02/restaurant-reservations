-- Extends create_reservation() with an optional p_order_id: when given, the
-- same call that creates the reservation also finalizes the linked draft
-- order (status -> 'confirmed', reservation_id set) in the same
-- transaction - this is the only place a reservation-with-order is ever
-- committed, matching the combined reservation+cart+payment page (nothing
-- commits before the final confirm click, and nothing partially commits if
-- any check fails).
--
-- The order is validated right next to the restaurant-row lock added in
-- the original migration (same "lock everything relevant before any
-- capacity read" concurrency story), so a double-submit or a
-- concurrently-emptied cart can't slip through. Every failure here raises
-- the same way every other check in this function does, which rolls back
-- the whole call - including any reservation_tables/reservation_sections
-- rows already inserted by the capacity branches below - since nothing
-- catches these exceptions except the pre-existing exclusion_violation
-- handler at the very end.
--
-- Signature changed (new trailing param), so the old 6-arg function is
-- dropped first rather than "create or replace" (which would only work for
-- an unchanged argument list and would otherwise leave the old 6-arg
-- version around as a separate overload). Existing callers are unaffected:
-- Supabase RPC calls pass named JSON arguments, and p_order_id defaults to
-- null.
drop function if exists public.create_reservation(uuid, integer, timestamptz, integer, uuid, uuid[]);

create function public.create_reservation(
  p_restaurant_id uuid,
  p_party_size integer,
  p_starts_at timestamptz,
  p_stay_minutes integer default null,
  p_section_id uuid default null,
  p_table_ids uuid[] default null,
  p_order_id uuid default null
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
  v_order public.orders;
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

  if p_order_id is not null then
    select * into v_order from public.orders where id = p_order_id for update;
    if not found or v_order.customer_id <> auth.uid() then
      raise exception 'Porudžbina ne postoji.';
    end if;
    if v_order.restaurant_id <> p_restaurant_id then
      raise exception 'Porudžbina pripada drugom restoranu.';
    end if;
    if v_order.status <> 'draft' then
      raise exception 'Porudžbina je već finalizovana.';
    end if;
    if not exists (select 1 from public.order_items where order_id = p_order_id) then
      raise exception 'Korpa je prazna.';
    end if;
    if exists (
      select 1 from public.order_items oi
      left join public.menu_items mi on mi.id = oi.menu_item_id
      where oi.order_id = p_order_id and (mi.id is null or not mi.is_available)
    ) then
      raise exception 'Neke stavke iz korpe više nisu dostupne. Vratite se na meni i ažurirajte porudžbinu.';
    end if;
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
        -- Two separate, individually-valid bookings that don't overlap
        -- each other can both overlap a wider query range and sum to more
        -- than capacity (e.g. two full-capacity bookings at [A,C) and
        -- [D,F) - neither conflicts with the other, but a request spanning
        -- [B,E) overlaps both) - clamp instead of reporting a negative
        -- "available" figure.
        raise exception 'Nema dovoljno slobodnih mesta u izabrano vreme (slobodno mesta: %).', greatest(0, v_capacity - v_booked);
      end if;
    end if;

    insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
    values (p_restaurant_id, auth.uid(), p_party_size, p_starts_at, v_ends_at, 'confirmed')
    returning id into v_reservation_id;
  end if;

  if p_order_id is not null then
    update public.orders
    set status = 'confirmed', reservation_id = v_reservation_id, confirmed_at = now()
    where id = p_order_id;
  end if;

  select * into v_reservation from public.reservations where id = v_reservation_id;
  return v_reservation;
exception
  when exclusion_violation then
    raise exception 'Sto je već rezervisan u to vreme.';
end;
$$;

grant execute on function public.create_reservation(uuid, integer, timestamptz, integer, uuid, uuid[], uuid) to authenticated;
