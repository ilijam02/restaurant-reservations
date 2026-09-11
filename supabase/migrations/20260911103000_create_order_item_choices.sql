-- Selected modifier choices for one order_items line (e.g. "Velika" under
-- "Velicina", plus "Extra Sir" under "Dodaci"). option_name/choice_name/
-- price_delta are snapshots taken at add_order_item() time, same reasoning
-- as order_items.item_name/unit_price - choice_id is nullable with "on
-- delete set null" so a later-deleted choice doesn't erase what a past
-- order actually contained. Purely descriptive: unit_price on the parent
-- order_items row already has every price_delta baked in, so nothing here
-- needs to be re-summed at checkout - these rows only exist so the cart/
-- receipt can *display* what was picked.
create table public.order_item_choices (
  id uuid primary key default gen_random_uuid(),
  order_item_id uuid not null references public.order_items (id) on delete cascade,
  choice_id uuid references public.menu_item_option_choices (id) on delete set null,
  option_name text not null,
  choice_name text not null,
  price_delta numeric(10, 2) not null default 0
);

create index order_item_choices_order_item_id_idx on public.order_item_choices (order_item_id);
create index order_item_choices_choice_id_idx on public.order_item_choices (choice_id);

alter table public.order_item_choices enable row level security;

-- select only - rows are only ever written by add_order_item() (security
-- definer) and removed via order_items' own cascade-on-delete, so no
-- client-facing insert/update/delete grant is needed at all.
grant select on public.order_item_choices to authenticated;

create policy "Customers can view their own order item choices"
  on public.order_item_choices for select
  to authenticated
  using (
    exists (
      select 1 from public.order_items oi
      join public.orders o on o.id = oi.order_id
      where oi.id = order_item_id and o.customer_id = auth.uid()
    )
  );

create policy "Owners can view choices on confirmed orders at their restaurants"
  on public.order_item_choices for select
  to authenticated
  using (
    exists (
      select 1 from public.order_items oi
      join public.orders o on o.id = oi.order_id
      join public.restaurants r on r.id = o.restaurant_id
      where oi.id = order_item_id and o.status = 'confirmed' and r.owner_id = auth.uid()
    )
  );

create policy "Staff can view choices on confirmed orders at their restaurants"
  on public.order_item_choices for select
  to authenticated
  using (
    exists (
      select 1 from public.order_items oi
      join public.orders o on o.id = oi.order_id
      join public.restaurant_staff rs on rs.restaurant_id = o.restaurant_id
      where oi.id = order_item_id and o.status = 'confirmed' and rs.employee_id = auth.uid() and rs.status = 'accepted'
    )
  );
