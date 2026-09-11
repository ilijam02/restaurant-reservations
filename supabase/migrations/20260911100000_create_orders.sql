-- Customer food orders. A row starts as a 'draft' shopping cart, built up
-- via start_cart()/add_order_item() below, and only ever becomes
-- 'confirmed' as part of create_reservation() finalizing the linked
-- reservation - there is no standalone "place order" action, matching the
-- combined reservation+order+payment flow this table exists for.
--
-- A customer has at most one 'draft' order at a time (see the partial
-- unique index below), not one per restaurant - starting a cart at a
-- different restaurant replaces whatever draft already existed, same
-- behavior as Wolt/Glovo. No cleanup job for abandoned drafts: a stray
-- draft row is harmless, the next start_cart() at that restaurant just
-- reuses or replaces it.
--
-- reservation_id has no "on delete" action (defaults to RESTRICT) rather
-- than cascade - reservations are never deleted today (only
-- cancelled/completed via status), but an order is a financial record and
-- shouldn't silently vanish if that ever changes.
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  customer_id uuid not null references auth.users (id) on delete cascade,
  status text not null default 'draft' check (status in ('draft', 'confirmed')),
  reservation_id uuid references public.reservations (id),
  created_at timestamptz not null default now(),
  confirmed_at timestamptz
);

create unique index orders_one_draft_per_customer_idx on public.orders (customer_id) where status = 'draft';
create index orders_restaurant_id_idx on public.orders (restaurant_id);
create index orders_reservation_id_idx on public.orders (reservation_id);

alter table public.orders enable row level security;

-- Only select is granted - there is deliberately no insert/update/delete
-- grant for authenticated, same reasoning as reservations. Every write goes
-- through start_cart()/add_order_item() (cart building) or
-- create_reservation() (finalizing), all security definer.
grant select on public.orders to authenticated;

create policy "Customers can view their own orders"
  on public.orders for select
  to authenticated
  using (customer_id = auth.uid());

-- Drafts are private carts, not visible to the restaurant until confirmed -
-- same as a Wolt basket the restaurant can't see until it's placed.
create policy "Owners can view confirmed orders at their restaurants"
  on public.orders for select
  to authenticated
  using (
    status = 'confirmed'
    and exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );

create policy "Staff can view confirmed orders at their restaurants"
  on public.orders for select
  to authenticated
  using (
    status = 'confirmed'
    and exists (
      select 1 from public.restaurant_staff rs
      where rs.restaurant_id = orders.restaurant_id
        and rs.employee_id = auth.uid()
        and rs.status = 'accepted'
    )
  );
