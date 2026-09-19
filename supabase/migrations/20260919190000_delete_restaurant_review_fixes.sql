-- Follow-ups from reviewing 20260919180000_delete_restaurant.sql.
--
-- 1. archived_at could still be set on INSERT: the insert grant is table-wide
--    and the policy only checked owner_id/role, so an owner could create a
--    restaurant that is already archived. The invariant is "only
--    delete_restaurant() sets archived_at", so the insert policy now requires
--    it to be null (an owner can't insert as archived, and a column-level
--    insert grant would have needed the same "remember to extend it" upkeep as
--    the update grant).
--
-- 2. "Active" for deletion now also requires the reservation not to have ended
--    yet. Between a reservation's ends_at and the next pg_cron sweep (up to a
--    minute) it still carries its old status, which used to block deleting the
--    restaurant - and "cancel all" couldn't clear it, because
--    cancel_reservation() rejects an expired reservation. An ended reservation
--    isn't occupying anything, so it no longer blocks. (A `confirmed` one that
--    has ended is recorded as a no-show by the sweep later, restaurant archived
--    or not.)
--
-- 3. The archived-restaurant insert guard read archived_at without locking the
--    row, so on restaurant_staff/orders an insert could fire the trigger just
--    before delete_restaurant() committed and still land afterwards (a stray,
--    invisible draft cart or pending application). It now takes a FOR KEY SHARE
--    lock on the restaurant row (which delete_restaurant()'s FOR UPDATE
--    conflicts with) so the two serialize: the insert either finishes first and
--    is then cleaned up by delete_restaurant(), or waits and sees archived_at.
--    (create_reservation() was never affected - it locks FOR UPDATE itself.)
--    The trigger function also no longer grants execute to authenticated/
--    service_role: a trigger doesn't need the caller to be able to execute it.

drop policy "Owner-role accounts can create restaurants" on public.restaurants;
create policy "Owner-role accounts can create restaurants"
  on public.restaurants for insert
  to authenticated
  with check (
    auth.uid() = owner_id
    and archived_at is null
    and exists (
      select 1 from public.profiles
      where id = auth.uid() and role = 'owner'
    )
  );

create or replace function public.prevent_insert_for_archived_restaurant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_archived_at timestamptz;
begin
  select archived_at into v_archived_at
  from public.restaurants
  where id = new.restaurant_id
  for key share;

  if v_archived_at is not null then
    raise exception 'Restoran ne postoji.';
  end if;
  return new;
end;
$$;

revoke all on function public.prevent_insert_for_archived_restaurant() from public, anon, authenticated, service_role;

create or replace function public.restaurant_deletion_plan(p_restaurant_id uuid)
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
      where res.restaurant_id = r.id
        and public.is_active_reservation_status(res.status)
        and res.ends_at > now())::integer,
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

create or replace function public.delete_restaurant(p_restaurant_id uuid)
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
    where res.restaurant_id = p_restaurant_id
      and public.is_active_reservation_status(res.status)
      and res.ends_at > now()
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
