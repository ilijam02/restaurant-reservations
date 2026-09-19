-- Deleting a restaurant (ISSUES.md: "Delete a restaurant").
--
-- Every child table references restaurants with "on delete cascade", so a bare
-- `delete from restaurants` silently wipes the restaurant's reservations and
-- orders too - customers' history and (once Stripe lands) the financial
-- records with it. So deleting is split in two, decided by the database:
--   * no reservation history -> the row is really deleted (the cascade takes
--     the layout, menu, staff and any draft carts with it);
--   * any reservation history -> the restaurant is archived instead
--     (archived_at set): hidden everywhere, but its reservations and orders
--     stay for the customers who made them.
-- Either way it is refused while any reservation is still active
-- (confirmed / preparing_order / order_prepared / ongoing). The hard-delete
-- branch is only reachable when there are no reservations at all, which also
-- sidesteps two cascade hazards: orders.reservation_id is RESTRICT (an
-- order/reservation cascade race) and the tables/sections delete guards only
-- protect anything if reservation_tables rows still exist when they fire.
--
-- Direct deletes from the Data API are closed off (grant + policy dropped): the
-- cascade above is exactly what an owner must not be able to trigger by hand.
-- Account deletion is unaffected - it cascades from auth.users as the admin.

alter table public.restaurants add column archived_at timestamptz;

revoke delete on public.restaurants from authenticated;
drop policy "Owners can delete their own restaurants" on public.restaurants;

-- archived_at may only be set by delete_restaurant() (a security definer
-- function, unaffected by grants) - otherwise an owner could hide a
-- restaurant from a plain update and skip the active-reservation check.
-- Column-level grant, same approach as profiles.role (see
-- 20260919140000_profiles_role_immutable.sql): a column added to restaurants
-- later has to be added to this list to be owner-editable.
revoke update on public.restaurants from authenticated;
grant update (name, capacity, default_stay_minutes, image_url, address, latitude, longitude)
  on public.restaurants to authenticated;

-- An archived restaurant can't take new reservations, carts or staff
-- applications. One trigger function on the three tables that point at a
-- restaurant, rather than editing create_reservation()/start_cart() and the
-- staff insert policy: create_reservation() locks the restaurant row before
-- inserting, so it can't slip past a concurrent archive.
create function public.prevent_insert_for_archived_restaurant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.restaurants
    where id = new.restaurant_id and archived_at is not null
  ) then
    raise exception 'Restoran ne postoji.';
  end if;
  return new;
end;
$$;

revoke all on function public.prevent_insert_for_archived_restaurant() from public, anon;

create trigger reservations_prevent_insert_for_archived_restaurant
  before insert on public.reservations
  for each row execute function public.prevent_insert_for_archived_restaurant();

create trigger orders_prevent_insert_for_archived_restaurant
  before insert on public.orders
  for each row execute function public.prevent_insert_for_archived_restaurant();

create trigger restaurant_staff_prevent_insert_for_archived_restaurant
  before insert on public.restaurant_staff
  for each row execute function public.prevent_insert_for_archived_restaurant();

-- What the delete confirmation shows the owner, and what the reservations
-- page needs to decide whether to offer "cancel all". No row at all for a
-- restaurant that doesn't exist, isn't theirs or is already archived (same
-- "not yours looks like missing" reasoning as cancel_reservation()).
create function public.restaurant_deletion_plan(p_restaurant_id uuid)
returns table (
  active_reservations integer,
  cancellable_reservations integer,
  total_reservations integer,
  staff_count integer,
  menu_item_count integer,
  table_count integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select count(*) from public.reservations res
      where res.restaurant_id = r.id and public.is_active_reservation_status(res.status))::integer,
    (select count(*) from public.reservations res
      where res.restaurant_id = r.id
        and res.status in ('confirmed', 'preparing_order', 'order_prepared')
        and res.ends_at > now())::integer,
    (select count(*) from public.reservations res where res.restaurant_id = r.id)::integer,
    (select count(*) from public.restaurant_staff rs where rs.restaurant_id = r.id)::integer,
    (select count(*) from public.menu_items mi where mi.restaurant_id = r.id)::integer,
    (select count(*) from public.tables t where t.restaurant_id = r.id)::integer
  from public.restaurants r
  where r.id = p_restaurant_id and r.owner_id = auth.uid() and r.archived_at is null;
$$;

revoke all on function public.restaurant_deletion_plan(uuid) from public, anon;
grant execute on function public.restaurant_deletion_plan(uuid) to authenticated;

-- Returns 'deleted' or 'archived'. The row is locked first: create_reservation()
-- takes the same lock, so a booking in flight either finishes before this
-- looks for active reservations or waits and is then refused.
--
-- Archiving also removes the staff rows (an ex-restaurant has no staff, and
-- accepted staff would otherwise keep read access to its reservations) and any
-- draft carts (they can never become a reservation now). It leaves the image
-- files alone - only the caller can remove those, and only while the row still
-- exists (the storage delete policy checks ownership through it), so the app
-- purges them before calling this on the no-history path.
create function public.delete_restaurant(p_restaurant_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1
  from public.restaurants
  where id = p_restaurant_id and owner_id = auth.uid() and archived_at is null
  for update;

  if not found then
    raise exception 'Restoran ne postoji.';
  end if;

  if exists (
    select 1 from public.reservations res
    where res.restaurant_id = p_restaurant_id and public.is_active_reservation_status(res.status)
  ) then
    raise exception 'Restoran ima aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.';
  end if;

  if exists (select 1 from public.reservations where restaurant_id = p_restaurant_id) then
    update public.restaurants set archived_at = now() where id = p_restaurant_id;
    delete from public.restaurant_staff where restaurant_id = p_restaurant_id;
    delete from public.orders where restaurant_id = p_restaurant_id and status = 'draft';
    return 'archived';
  end if;

  delete from public.restaurants where id = p_restaurant_id;
  return 'deleted';
end;
$$;

revoke all on function public.delete_restaurant(uuid) from public, anon;
grant execute on function public.delete_restaurant(uuid) to authenticated;

-- Owner-only "cancel everything still cancellable" for one restaurant, so it
-- can be cleared before deleting it. Goes through cancel_reservation() per
-- reservation (audit columns, order cancellation and slot freeing come with
-- it). Reservations that can't be cancelled - an ongoing one, or one that
-- changed or expired between the list query and its turn - are skipped rather
-- than aborting the rest; the count of those actually cancelled is returned.
create function public.cancel_all_active_reservations(p_restaurant_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_count integer := 0;
begin
  if not exists (
    select 1 from public.restaurants
    where id = p_restaurant_id and owner_id = auth.uid() and archived_at is null
  ) then
    raise exception 'Restoran ne postoji.';
  end if;

  for v_id in
    select id from public.reservations
    where restaurant_id = p_restaurant_id
      and status in ('confirmed', 'preparing_order', 'order_prepared')
      and ends_at > now()
    order by starts_at
  loop
    begin
      perform public.cancel_reservation(v_id);
      v_count := v_count + 1;
    exception
      when raise_exception then
        null;
    end;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.cancel_all_active_reservations(uuid) from public, anon;
grant execute on function public.cancel_all_active_reservations(uuid) to authenticated;
