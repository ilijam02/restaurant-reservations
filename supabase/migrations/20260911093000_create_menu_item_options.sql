-- Modifier groups on a menu item (e.g. a required single-select
-- "Velicina" group, or an optional multi-select "Dodaci" group). The
-- actual pickable values live in menu_item_option_choices, one level
-- deeper. Ownership is checked by joining up through menu_item_id to the
-- item's restaurant - there is no restaurant_id column here, same as
-- tables being scoped through layout_id/section_id rather than
-- duplicating restaurant_id's ownership check at every level.
create table public.menu_item_options (
  id uuid primary key default gen_random_uuid(),
  menu_item_id uuid not null references public.menu_items (id) on delete cascade,
  name text not null,
  is_required boolean not null default false,
  allow_multiple boolean not null default false,
  display_order integer not null default 0,
  created_at timestamptz not null default now()
);

create index menu_item_options_menu_item_id_idx on public.menu_item_options (menu_item_id);

alter table public.menu_item_options enable row level security;

-- Explicit grants: this project has "automatically expose new tables"
-- disabled, so nothing is reachable via the Data API until granted here.
grant select, insert, update, delete on public.menu_item_options to authenticated;

create policy "Authenticated users can view menu item options"
  on public.menu_item_options for select
  to authenticated
  using (true);

create policy "Owners can add options to their own restaurants' menu items"
  on public.menu_item_options for insert
  to authenticated
  with check (
    exists (
      select 1 from public.menu_items mi
      join public.restaurants r on r.id = mi.restaurant_id
      where mi.id = menu_item_options.menu_item_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can update their own restaurants' menu item options"
  on public.menu_item_options for update
  to authenticated
  using (
    exists (
      select 1 from public.menu_items mi
      join public.restaurants r on r.id = mi.restaurant_id
      where mi.id = menu_item_options.menu_item_id and r.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.menu_items mi
      join public.restaurants r on r.id = mi.restaurant_id
      where mi.id = menu_item_options.menu_item_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can delete their own restaurants' menu item options"
  on public.menu_item_options for delete
  to authenticated
  using (
    exists (
      select 1 from public.menu_items mi
      join public.restaurants r on r.id = mi.restaurant_id
      where mi.id = menu_item_options.menu_item_id and r.owner_id = auth.uid()
    )
  );
