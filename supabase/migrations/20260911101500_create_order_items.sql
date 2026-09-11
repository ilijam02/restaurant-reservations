-- One row per cart/order line. item_name and unit_price are snapshots
-- taken at add_order_item() time, not live references - unit_price is the
-- item's base price plus every selected choice's price_delta, already
-- summed, so quantity * unit_price is the line total without joining back
-- to order_item_choices. menu_item_id is nullable with "on delete set
-- null" (not cascade): if an owner deletes a menu item later, historic
-- order lines keep their snapshotted name/price rather than silently
-- losing a receipt line.
--
-- Prices are never client-writable: add_order_item() (security definer)
-- computes unit_price itself from the current menu_items/menu_item_option_choices
-- rows and is the only way to insert here (no insert grant below). The one
-- thing a customer can change afterward is quantity, via a column-level
-- grant - see the grant statement below.
create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  menu_item_id uuid references public.menu_items (id) on delete set null,
  item_name text not null,
  unit_price numeric(10, 2) not null check (unit_price >= 0),
  quantity integer not null default 1 check (quantity > 0),
  created_at timestamptz not null default now()
);

create index order_items_order_id_idx on public.order_items (order_id);
create index order_items_menu_item_id_idx on public.order_items (menu_item_id);

alter table public.order_items enable row level security;

-- No insert grant - rows are only ever created by add_order_item()
-- (security definer), which is what actually computes unit_price. update is
-- granted on the quantity column only - even a raw client .update() call
-- can't touch price/item_name/order_id, only how many of that already-priced
-- line the customer wants.
grant select, delete on public.order_items to authenticated;
grant update (quantity) on public.order_items to authenticated;

create policy "Customers can view their own order items"
  on public.order_items for select
  to authenticated
  using (
    exists (
      select 1 from public.orders o
      where o.id = order_id and o.customer_id = auth.uid()
    )
  );

create policy "Owners can view items on confirmed orders at their restaurants"
  on public.order_items for select
  to authenticated
  using (
    exists (
      select 1 from public.orders o
      join public.restaurants r on r.id = o.restaurant_id
      where o.id = order_id and o.status = 'confirmed' and r.owner_id = auth.uid()
    )
  );

create policy "Staff can view items on confirmed orders at their restaurants"
  on public.order_items for select
  to authenticated
  using (
    exists (
      select 1 from public.orders o
      join public.restaurant_staff rs on rs.restaurant_id = o.restaurant_id
      where o.id = order_id and o.status = 'confirmed' and rs.employee_id = auth.uid() and rs.status = 'accepted'
    )
  );

-- Cart lines can only be changed/removed while still a draft - once an
-- order is confirmed it's a fixed record of what was actually ordered.
create policy "Customers can update quantity on their own draft order items"
  on public.order_items for update
  to authenticated
  using (
    exists (
      select 1 from public.orders o
      where o.id = order_id and o.customer_id = auth.uid() and o.status = 'draft'
    )
  )
  with check (
    exists (
      select 1 from public.orders o
      where o.id = order_id and o.customer_id = auth.uid() and o.status = 'draft'
    )
  );

create policy "Customers can remove their own draft order items"
  on public.order_items for delete
  to authenticated
  using (
    exists (
      select 1 from public.orders o
      where o.id = order_id and o.customer_id = auth.uid() and o.status = 'draft'
    )
  );
