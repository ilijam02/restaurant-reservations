-- Owner-defined groupings for menu items (e.g. "Predjela", "Glavna jela").
-- Optional - an item can be uncategorized (see menu_items.category_id).
-- display_order is a plain integer the owner controls via reorder
-- buttons in the UI; no uniqueness or gap-free requirement on it.
create table public.menu_categories (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  name text not null,
  display_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (restaurant_id, name)
);

create index menu_categories_restaurant_id_idx on public.menu_categories (restaurant_id);

alter table public.menu_categories enable row level security;

-- Explicit grants: this project has "automatically expose new tables"
-- disabled, so nothing is reachable via the Data API until granted here.
grant select, insert, update, delete on public.menu_categories to authenticated;

-- Same public-read shape as sections/tables - customers and employees will
-- need to read the menu later.
create policy "Authenticated users can view menu categories"
  on public.menu_categories for select
  to authenticated
  using (true);

create policy "Owners can add menu categories to their own restaurants"
  on public.menu_categories for insert
  to authenticated
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = menu_categories.restaurant_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can update their own restaurant menu categories"
  on public.menu_categories for update
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = menu_categories.restaurant_id and r.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = menu_categories.restaurant_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can delete their own restaurant menu categories"
  on public.menu_categories for delete
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = menu_categories.restaurant_id and r.owner_id = auth.uid()
    )
  );
