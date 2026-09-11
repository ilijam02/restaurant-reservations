-- Menu items an owner sells. category_id is nullable - items can be
-- uncategorized, same optionality pattern as tables.section_id - and uses
-- on delete set null so removing a category doesn't delete the items in
-- it, it just uncategorizes them.
--
-- image_url is nullable and unused by any UI yet - deliberately no owner
-- upload flow in this pass. When null, the app renders a client-side SVG
-- placeholder instead (see MenuItemImage), so there is no "default image"
-- value stored here.
--
-- price has no currency column - the app is Serbian-only elsewhere too, so
-- a single implied currency (RSD) is assumed rather than modeled.
create table public.menu_items (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  category_id uuid references public.menu_categories (id) on delete set null,
  name text not null,
  description text,
  price numeric(10, 2) not null,
  image_url text,
  is_available boolean not null default true,
  display_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint menu_items_price_non_negative check (price >= 0)
);

create index menu_items_restaurant_id_idx on public.menu_items (restaurant_id);
create index menu_items_category_id_idx on public.menu_items (category_id);

alter table public.menu_items enable row level security;

-- Explicit grants: this project has "automatically expose new tables"
-- disabled, so nothing is reachable via the Data API until granted here.
grant select, insert, update, delete on public.menu_items to authenticated;

-- Same public-read shape as sections/tables - customers and employees will
-- need to read the menu later.
create policy "Authenticated users can view menu items"
  on public.menu_items for select
  to authenticated
  using (true);

-- category_id ids aren't secret (menu_categories has the same
-- any-authenticated-user select policy as everything else in this app), so
-- the insert/update checks below explicitly verify it belongs to the same
-- restaurant as restaurant_id - not just that restaurant_id itself is
-- owned by the caller - same reasoning as tables.section_id/layout_id.
create policy "Owners can add menu items to their own restaurants"
  on public.menu_items for insert
  to authenticated
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = menu_items.restaurant_id and r.owner_id = auth.uid()
    )
    and (
      menu_items.category_id is null
      or exists (
        select 1 from public.menu_categories c
        where c.id = menu_items.category_id and c.restaurant_id = menu_items.restaurant_id
      )
    )
  );

create policy "Owners can update their own restaurant menu items"
  on public.menu_items for update
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = menu_items.restaurant_id and r.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = menu_items.restaurant_id and r.owner_id = auth.uid()
    )
    and (
      menu_items.category_id is null
      or exists (
        select 1 from public.menu_categories c
        where c.id = menu_items.category_id and c.restaurant_id = menu_items.restaurant_id
      )
    )
  );

create policy "Owners can delete their own restaurant menu items"
  on public.menu_items for delete
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = menu_items.restaurant_id and r.owner_id = auth.uid()
    )
  );
