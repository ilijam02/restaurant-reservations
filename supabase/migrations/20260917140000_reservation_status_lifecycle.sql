-- Extends reservations.status with a fuller service lifecycle -
-- confirmed -> [preparing_order -> order_prepared ->] ongoing -> completed,
-- plus confirmed/order_prepared -> no_show (only once starts_at has
-- passed) - and adds update_reservation_status() so accepted staff can
-- drive it from the employee reservations page (ISSUES.md: "Update the
-- status of customers' reservations" / "Reservation/order status
-- notifications" - see the design chat for the full transition graph).
-- preparing_order/order_prepared only apply when the reservation has a
-- linked confirmed order - otherwise the flow skips straight
-- confirmed -> ongoing. cancelled stays unreachable through this RPC - a
-- customer-initiated cancel is still its own separate backlog item.
--
-- "Active" (occupying a table/section) used to mean exactly status =
-- 'confirmed' everywhere - create_reservation()'s overlap checks,
-- get_occupied_table_ids()/get_section_remaining_capacity(), and all
-- capacity-guard functions from
-- 20260913140000_protect_capacity_from_active_reservations.sql and its
-- follow-ups. Widened here (via is_active_reservation_status()) to
-- confirmed/preparing_order/order_prepared/ongoing, so a reservation that's
-- mid-service still blocks new bookings for its table/section the same way
-- a plain 'confirmed' one always has. Natural roll-off into 'completed'
-- once ends_at passes needs no new machinery - it falls out of the
-- existing "... and ends_at >= now()" pattern every one of these already
-- uses, same as the customer current/past split.
create or replace function public.is_active_reservation_status(p_status text)
returns boolean
language sql
immutable
as $$
  select p_status in ('confirmed', 'preparing_order', 'order_prepared', 'ongoing');
$$;

-- The original check constraint's name wasn't set explicitly, so this finds
-- whatever Postgres auto-generated for it rather than assuming
-- "reservations_status_check" is exactly right.
do $$
declare
  v_conname text;
begin
  select conname into v_conname
  from pg_constraint
  where conrelid = 'public.reservations'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%status%';

  if v_conname is not null then
    execute format('alter table public.reservations drop constraint %I', v_conname);
  end if;
end $$;

alter table public.reservations add constraint reservations_status_check
  check (status in ('confirmed', 'preparing_order', 'order_prepared', 'ongoing', 'completed', 'no_show', 'cancelled'));

-- --- Widen every "status = 'confirmed'" capacity/availability check to
-- --- is_active_reservation_status() (create or replace, same signatures
-- --- throughout, so every existing grant stays intact) ---

create or replace function public.create_reservation(
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

  v_starts_local := p_starts_at at time zone 'Europe/Belgrade';
  v_ends_local := v_ends_at at time zone 'Europe/Belgrade';
  v_start_date := v_starts_local::date;

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
            and public.is_active_reservation_status(res.status)
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
    v_remaining := p_party_size;
    v_chosen_section_ids := '{}';
    v_chosen_section_allocs := '{}';
    for r in (
      select s.id,
        s.capacity - coalesce((
          select sum(rs.party_size) from public.reservation_sections rs
          join public.reservations res on res.id = rs.reservation_id
          where rs.section_id = s.id
            and public.is_active_reservation_status(res.status)
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
    v_capacity := v_restaurant.capacity;
    if v_capacity is not null then
      select coalesce(sum(party_size), 0) into v_booked
      from public.reservations
      where restaurant_id = p_restaurant_id
        and public.is_active_reservation_status(status)
        and tstzrange(starts_at, ends_at) && tstzrange(p_starts_at, v_ends_at);

      if v_booked + p_party_size > v_capacity then
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

create or replace function public.get_occupied_table_ids(
  p_restaurant_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz
)
returns table (table_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct rt.table_id
  from public.reservation_tables rt
  join public.reservations r on r.id = rt.reservation_id
  join public.tables t on t.id = rt.table_id
  where t.restaurant_id = p_restaurant_id
    and public.is_active_reservation_status(r.status)
    and tstzrange(rt.starts_at, rt.ends_at) && tstzrange(p_starts_at, p_ends_at);
$$;

create or replace function public.get_section_remaining_capacity(
  p_restaurant_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz
)
returns table (section_id uuid, remaining integer)
language sql
stable
security definer
set search_path = ''
as $$
  select
    s.id,
    greatest(0, s.capacity - coalesce((
      select sum(rs.party_size) from public.reservation_sections rs
      join public.reservations r on r.id = rs.reservation_id
      where rs.section_id = s.id
        and public.is_active_reservation_status(r.status)
        and tstzrange(r.starts_at, r.ends_at) && tstzrange(p_starts_at, p_ends_at)
    ), 0))::integer
  from public.sections s
  where s.restaurant_id = p_restaurant_id;
$$;

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
      and public.is_active_reservation_status(status)
      and ends_at >= now()
    union all
    select ends_at as t, -party_size as delta
    from public.reservations
    where restaurant_id = p_restaurant_id
      and public.is_active_reservation_status(status)
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
      and public.is_active_reservation_status(r.status)
      and r.ends_at >= now()
    union all
    select r.ends_at as t, -rs.party_size as delta
    from public.reservation_sections rs
    join public.reservations r on r.id = rs.reservation_id
    where rs.section_id = p_section_id
      and public.is_active_reservation_status(r.status)
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
declare
  v_starts_at timestamptz;
  v_party_size integer;
begin
  select r.starts_at, r.party_size into v_starts_at, v_party_size
  from public.reservation_tables rt
  join public.reservations r on r.id = rt.reservation_id
  where rt.table_id = old.id
    and public.is_active_reservation_status(r.status)
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
    and public.is_active_reservation_status(r.status)
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
    and public.is_active_reservation_status(r.status)
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
    and public.is_active_reservation_status(r.status)
    and r.ends_at >= now()
  order by s.id, r.starts_at;
$$;

-- --- The new RPC itself ---
--
-- security definer (same reasoning as create_reservation - reservations has
-- no update grant for authenticated at all) + set search_path = '', this
-- project's standing convention. Called by accepted staff only (not the
-- owner - the design chat drew this line deliberately: staff run service,
-- owners manage the restaurant's setup).
--
-- Early completion/no_show: both can fire before the reservation's booked
-- ends_at (an "ongoing" reservation might genuinely finish early; a no-show
-- is only ever discovered after starts_at, often well before the booked
-- ends_at). Both cases shrink ends_at down to now() - on reservations and
-- on its reservation_tables rows (the only child table that denormalizes
-- the time range, for the exclusion constraint's sake - reservation_sections
-- has no times of its own, it joins back to reservations directly) - so the
-- freed remainder of the slot is immediately bookable again through the
-- exact same is_active_reservation_status()/ends_at >= now() checks every
-- capacity function above already makes. Clamped to never land at or before
-- starts_at (technically reachable since confirmed/order_prepared -> ongoing
-- has no timing gate of its own), which would violate reservations' own
-- ends_at > starts_at check constraint.
create or replace function public.update_reservation_status(
  p_reservation_id uuid,
  p_new_status text
)
returns public.reservations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.reservations;
  v_has_order boolean;
  v_new_ends_at timestamptz;
begin
  select * into v_reservation from public.reservations where id = p_reservation_id for update;
  if not found then
    raise exception 'Rezervacija ne postoji.';
  end if;

  if not exists (
    select 1 from public.restaurant_staff rs
    where rs.restaurant_id = v_reservation.restaurant_id
      and rs.employee_id = auth.uid()
      and rs.status = 'accepted'
  ) then
    raise exception 'Nemate dozvolu da menjate status ove rezervacije.';
  end if;

  v_has_order := exists (
    select 1 from public.orders o
    where o.reservation_id = p_reservation_id and o.status = 'confirmed'
  );

  if p_new_status = 'preparing_order' then
    if v_reservation.status <> 'confirmed' or not v_has_order then
      raise exception 'Priprema porudžbine je moguća samo iz statusa "Potvrđena" rezervacije koja ima porudžbinu.';
    end if;

  elsif p_new_status = 'order_prepared' then
    if v_reservation.status <> 'preparing_order' then
      raise exception 'Porudžbina može biti označena kao spremna samo dok se priprema.';
    end if;

  elsif p_new_status = 'ongoing' then
    if v_reservation.status = 'confirmed' and v_has_order then
      raise exception 'Rezervacija ima porudžbinu - prvo je potrebno pripremiti je.';
    end if;
    if v_reservation.status not in ('confirmed', 'order_prepared') then
      raise exception 'Rezervacija mora biti potvrđena ili imati spremnu porudžbinu pre početka.';
    end if;

  elsif p_new_status = 'no_show' then
    if v_reservation.status not in ('confirmed', 'order_prepared') then
      raise exception 'Gost može biti označen kao odsutan samo dok se čeka na dolazak.';
    end if;
    if v_reservation.starts_at > now() then
      raise exception 'Gost može biti označen kao odsutan tek nakon početka rezervacije.';
    end if;

  elsif p_new_status = 'completed' then
    if v_reservation.status <> 'ongoing' then
      raise exception 'Rezervacija mora biti u toku pre nego što se završi.';
    end if;

  else
    raise exception 'Nepoznat ili nepodržan status: %.', p_new_status;
  end if;

  v_new_ends_at := v_reservation.ends_at;
  if p_new_status in ('completed', 'no_show') then
    v_new_ends_at := least(v_reservation.ends_at, greatest(now(), v_reservation.starts_at + interval '1 second'));
  end if;

  update public.reservations
  set status = p_new_status, ends_at = v_new_ends_at
  where id = p_reservation_id;

  if v_new_ends_at < v_reservation.ends_at then
    update public.reservation_tables
    set ends_at = v_new_ends_at
    where reservation_id = p_reservation_id;
  end if;

  select * into v_reservation from public.reservations where id = p_reservation_id;
  return v_reservation;
end;
$$;

grant execute on function public.update_reservation_status(uuid, text) to authenticated;
