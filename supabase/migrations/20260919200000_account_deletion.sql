-- Account deletion (ISSUES.md: "Account deletion").
--
-- A bare `delete from auth.users` cascades into data that belongs to other
-- people: a customer's reservations/orders are wiped from the restaurants'
-- history (and, once Stripe lands, from the financial records), and an owner's
-- restaurants take every customer's reservations at them along - exactly what
-- delete_restaurant() exists to prevent. So deleting an account is a
-- database-decided operation, delete_my_account(), and the three foreign keys
-- that would have cascaded now detach instead:
--   * reservations.customer_id / orders.customer_id -> set null. The customer's
--     history stays, anonymized: those rows hold no name/phone/notes, and the
--     profile row is deleted with the user. This also makes the RESTRICT on
--     orders.reservation_id irrelevant - no reservation or order is deleted.
--   * restaurants.owner_id -> set null. By the time the user row goes, every
--     restaurant they owned is either deleted or archived (see below), so only
--     archived restaurants can be left pointing at them: detached, invisible,
--     kept for their customers' history.
--
-- Refused (not silently handled) while anything is still active - same
-- "active" as delete_restaurant(): confirmed / preparing_order / order_prepared
-- / ongoing and not yet ended. A customer's own active booking would otherwise
-- become an unowned booking that keeps a table blocked; an owner's would be
-- cancelled without anyone deciding to.
--
-- Nothing here touches Storage: deleting storage.objects rows in SQL leaves the
-- files in the bucket, so the app removes an owner's image folders through the
-- Storage API first, using restaurants_to_delete from account_deletion_plan()
-- (the same order of operations as deleting a single restaurant).

alter table public.reservations alter column customer_id drop not null;
alter table public.reservations
  drop constraint reservations_customer_id_fkey,
  add constraint reservations_customer_id_fkey
    foreign key (customer_id) references auth.users (id) on delete set null;

alter table public.orders alter column customer_id drop not null;
alter table public.orders
  drop constraint orders_customer_id_fkey,
  add constraint orders_customer_id_fkey
    foreign key (customer_id) references auth.users (id) on delete set null;

alter table public.restaurants alter column owner_id drop not null;
alter table public.restaurants
  drop constraint restaurants_owner_id_fkey,
  add constraint restaurants_owner_id_fkey
    foreign key (owner_id) references auth.users (id) on delete set null;

-- What the "Moj nalog" page shows before the user confirms, and what the
-- Server Action needs to purge images. One row for the caller (no row if they
-- have no profile). Deliberately role-agnostic - it counts whatever the caller
-- has as a customer and whatever they own - so a booking made by an owner-role
-- account can't slip past a role check either.
create function public.account_deletion_plan()
returns table (
  role text,
  active_reservations integer,
  history_reservations integer,
  blocking_restaurants jsonb,
  restaurants_to_delete uuid[],
  restaurants_to_archive integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.role,
    -- Own active bookings as a customer.
    (select count(*) from public.reservations res
      where res.customer_id = p.id
        and public.is_active_reservation_status(res.status)
        and res.ends_at > now())::integer,
    -- Everything they booked, which stays behind anonymized.
    (select count(*) from public.reservations res where res.customer_id = p.id)::integer,
    -- Owned restaurants that have an active reservation, with the count.
    coalesce((
      select jsonb_agg(
        jsonb_build_object('id', r.id, 'name', r.name, 'active_reservations', c.n)
        order by r.name
      )
      from public.restaurants r
      cross join lateral (
        select count(*) as n from public.reservations res
        where res.restaurant_id = r.id
          and public.is_active_reservation_status(res.status)
          and res.ends_at > now()
      ) c
      where r.owner_id = p.id and r.archived_at is null and c.n > 0
    ), '[]'::jsonb),
    -- Owned restaurants with no reservation history: really deleted, so their
    -- image folders have to be purged first.
    coalesce((
      select array_agg(r.id order by r.name)
      from public.restaurants r
      where r.owner_id = p.id and r.archived_at is null
        and not exists (select 1 from public.reservations res where res.restaurant_id = r.id)
    ), '{}'::uuid[]),
    -- Owned restaurants with history: archived (and detached from the owner).
    (select count(*) from public.restaurants r
      where r.owner_id = p.id and r.archived_at is null
        and exists (select 1 from public.reservations res where res.restaurant_id = r.id))::integer
  from public.profiles p
  where p.id = auth.uid();
$$;

revoke all on function public.account_deletion_plan() from public, anon;
grant execute on function public.account_deletion_plan() to authenticated;

-- Deletes the caller's own account - no id parameter, so it can only ever be
-- the caller. security definer because deleting from auth.users is beyond the
-- Data API roles; everything else it does is the caller's own data.
--
-- The auth.users row is locked FIRST. A booking insert takes FOR KEY SHARE on
-- its customer's row (the foreign key check), which conflicts with this lock,
-- so a booking made from another tab either lands before it - and the
-- active-reservation check below sees it - or waits and then fails its foreign
-- key once the user is gone. Either way no active booking is left ownerless.
--
-- Owners: every restaurant goes through delete_restaurant() (deleted if it has
-- no reservations, archived otherwise), which re-checks and locks each one
-- itself; if any of them refuses, this whole call rolls back. Draft carts are
-- deleted - they're private and meaningless without a customer.
create function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_blocking_name text;
  v_restaurant_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Nalog ne postoji.';
  end if;

  perform 1 from auth.users where id = auth.uid() for update;
  if not found then
    raise exception 'Nalog ne postoji.';
  end if;

  if exists (
    select 1 from public.reservations res
    where res.customer_id = auth.uid()
      and public.is_active_reservation_status(res.status)
      and res.ends_at > now()
  ) then
    raise exception 'Imate aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.';
  end if;

  select r.name into v_blocking_name
  from public.restaurants r
  where r.owner_id = auth.uid()
    and r.archived_at is null
    and exists (
      select 1 from public.reservations res
      where res.restaurant_id = r.id
        and public.is_active_reservation_status(res.status)
        and res.ends_at > now()
    )
  order by r.name
  limit 1;
  if found then
    raise exception 'Restoran „%” ima aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.', v_blocking_name;
  end if;

  for v_restaurant_id in
    select id from public.restaurants
    where owner_id = auth.uid() and archived_at is null
  loop
    perform public.delete_restaurant(v_restaurant_id);
  end loop;

  delete from public.orders where customer_id = auth.uid() and status = 'draft';

  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
