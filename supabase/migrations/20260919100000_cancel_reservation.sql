-- Reservation cancellation (ISSUES.md: "Cancel a reservation"), by the
-- customer who made the booking or by the owner of the restaurant it's at.
-- Allowed only while the reservation is confirmed / preparing_order /
-- order_prepared - i.e. before the guest has been seated. Staff (employees)
-- can't cancel: they run service, they don't decide to drop a booking.
--
-- Cancelling also cancels the reservation's linked order. There is no real
-- payment yet (the Stripe step is still a placeholder), so there's nothing
-- to refund - when payments land, this function is where a refund/void
-- has to be added.
--
-- Freeing the table slot: reservation_tables' exclusion constraint isn't
-- status-aware (see the comment in create_reservations.sql), so a cancelled
-- reservation would keep blocking its table/time slot unless its
-- reservation_tables rows stop covering that range. Like completed/no_show
-- in update_reservation_status(), the rows are shrunk to now() - but a plain
-- "ends_at = now()" is wrong here, because a cancelled reservation is
-- usually still in the future (starts_at > now()), and that would leave
-- ends_at before starts_at. So starts_at moves to now() as well: the row
-- becomes an empty range (starts_at = ends_at), which overlaps nothing, so
-- the exclusion constraint can never fire on it - not even against another
-- reservation on the same table that is running right now. (Shrinking to a
-- non-empty range like [now() - 1s, now()) would collide with exactly that.)
--
-- The reservations row itself keeps its booked starts_at/ends_at: its own
-- check constraint (ends_at > starts_at) rules out an empty range, nothing
-- reads a cancelled reservation's range (every capacity check filters on
-- is_active_reservation_status()), and the customer's/owner's lists keep
-- showing when the table had actually been booked for.

-- orders.status gains 'cancelled'. The original check's name wasn't set
-- explicitly (same situation as reservations.status in the lifecycle
-- migration), so this finds whatever Postgres auto-generated.
do $$
declare
  v_conname text;
begin
  select conname into v_conname
  from pg_constraint
  where conrelid = 'public.orders'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%status%';

  if v_conname is not null then
    execute format('alter table public.orders drop constraint %I', v_conname);
  end if;
end $$;

alter table public.orders add constraint orders_status_check
  check (status in ('draft', 'confirmed', 'cancelled'));

-- Owners keep seeing an order after its reservation is cancelled (the
-- owner reservations list shows it the same way the customer's does).
-- Drafts stay private, as before. Staff policies are left as they were:
-- cancelled reservations never appear on the employee page.
drop policy "Owners can view confirmed orders at their restaurants" on public.orders;
create policy "Owners can view confirmed and cancelled orders at their restaurants"
  on public.orders for select
  to authenticated
  using (
    status in ('confirmed', 'cancelled')
    and exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );

drop policy "Owners can view items on confirmed orders at their restaurants" on public.order_items;
create policy "Owners can view items on confirmed and cancelled orders at their restaurants"
  on public.order_items for select
  to authenticated
  using (
    exists (
      select 1 from public.orders o
      join public.restaurants r on r.id = o.restaurant_id
      where o.id = order_id and o.status in ('confirmed', 'cancelled') and r.owner_id = auth.uid()
    )
  );

drop policy "Owners can view choices on confirmed orders at their restaurants" on public.order_item_choices;
create policy "Owners can view choices on confirmed and cancelled orders at their restaurants"
  on public.order_item_choices for select
  to authenticated
  using (
    exists (
      select 1 from public.order_items oi
      join public.orders o on o.id = oi.order_id
      join public.restaurants r on r.id = o.restaurant_id
      where oi.id = order_item_id and o.status in ('confirmed', 'cancelled') and r.owner_id = auth.uid()
    )
  );

-- The owner's reservations list shows who booked, so an owner needs to read
-- the profile of a customer with a reservation at one of their restaurants.
-- A security definer function rather than an inline subquery for the same
-- reason as is_restaurant_owner_of_employee(): the reservations/restaurant_staff
-- policies and this one would otherwise re-enter each other's RLS (42P17).
-- Note this exposes the customer's whole profile row (phone included), not
-- just the name - column-level limits aren't possible per policy - which is
-- the same reach owners already have over their staff's profiles.
create function public.is_restaurant_owner_of_customer(customer uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.reservations res
    join public.restaurants r on r.id = res.restaurant_id
    where res.customer_id = customer and r.owner_id = auth.uid()
  );
$$;

revoke all on function public.is_restaurant_owner_of_customer(uuid) from public, anon;
grant execute on function public.is_restaurant_owner_of_customer(uuid) to authenticated;

create policy "Owners can view profiles of customers who reserved at their restaurants"
  on public.profiles for select
  to authenticated
  using (public.is_restaurant_owner_of_customer(profiles.id));

-- security definer (reservations/orders have no update grant for
-- authenticated at all) + set search_path = '', this project's standing
-- convention. The permission check is folded into the row lookup, so "no such
-- reservation" and "not yours" are indistinguishable to the caller (no id
-- oracle) - same reasoning as the lifecycle review fixes.
create or replace function public.cancel_reservation(p_reservation_id uuid)
returns public.reservations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.reservations;
begin
  select res.* into v_reservation
  from public.reservations res
  where res.id = p_reservation_id
    and (
      res.customer_id = auth.uid()
      or exists (
        select 1 from public.restaurants r
        where r.id = res.restaurant_id and r.owner_id = auth.uid()
      )
    )
  for update;

  if not found then
    raise exception 'Rezervacija ne postoji.';
  end if;

  if v_reservation.status not in ('confirmed', 'preparing_order', 'order_prepared') then
    raise exception 'Rezervacija može biti otkazana samo dok je potvrđena ili se porudžbina priprema.';
  end if;

  -- Between ends_at and the next pg_cron sweep (up to a minute) an expired
  -- reservation still carries its old status; without this it could be
  -- cancelled just before the sweep records it as a no-show.
  if v_reservation.ends_at <= now() then
    raise exception 'Rezervacija je već istekla.';
  end if;

  update public.reservations set status = 'cancelled' where id = p_reservation_id;

  update public.reservation_tables
  set starts_at = now(), ends_at = now()
  where reservation_id = p_reservation_id;

  update public.orders
  set status = 'cancelled'
  where reservation_id = p_reservation_id and status = 'confirmed';

  select * into v_reservation from public.reservations where id = p_reservation_id;
  return v_reservation;
end;
$$;

revoke all on function public.cancel_reservation(uuid) from public, anon;
grant execute on function public.cancel_reservation(uuid) to authenticated;
