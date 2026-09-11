-- The actual pickable values within a menu_item_options group (e.g.
-- "Mala"/"Srednja"/"Velika" under a "Velicina" group), each with its own
-- price_delta applied on top of the item's base price. Ownership is
-- checked by joining up through option_id -> menu_item_id -> restaurant,
-- same reasoning as menu_item_options itself.
create table public.menu_item_option_choices (
  id uuid primary key default gen_random_uuid(),
  option_id uuid not null references public.menu_item_options (id) on delete cascade,
  name text not null,
  price_delta numeric(10, 2) not null default 0,
  display_order integer not null default 0,
  created_at timestamptz not null default now()
);

create index menu_item_option_choices_option_id_idx on public.menu_item_option_choices (option_id);

alter table public.menu_item_option_choices enable row level security;

-- Explicit grants: this project has "automatically expose new tables"
-- disabled, so nothing is reachable via the Data API until granted here.
grant select, insert, update, delete on public.menu_item_option_choices to authenticated;

create policy "Authenticated users can view menu item option choices"
  on public.menu_item_option_choices for select
  to authenticated
  using (true);

create policy "Owners can add choices to their own restaurants' menu item options"
  on public.menu_item_option_choices for insert
  to authenticated
  with check (
    exists (
      select 1 from public.menu_item_options o
      join public.menu_items mi on mi.id = o.menu_item_id
      join public.restaurants r on r.id = mi.restaurant_id
      where o.id = menu_item_option_choices.option_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can update their own restaurants' menu item option choices"
  on public.menu_item_option_choices for update
  to authenticated
  using (
    exists (
      select 1 from public.menu_item_options o
      join public.menu_items mi on mi.id = o.menu_item_id
      join public.restaurants r on r.id = mi.restaurant_id
      where o.id = menu_item_option_choices.option_id and r.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.menu_item_options o
      join public.menu_items mi on mi.id = o.menu_item_id
      join public.restaurants r on r.id = mi.restaurant_id
      where o.id = menu_item_option_choices.option_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can delete their own restaurants' menu item option choices"
  on public.menu_item_option_choices for delete
  to authenticated
  using (
    exists (
      select 1 from public.menu_item_options o
      join public.menu_items mi on mi.id = o.menu_item_id
      join public.restaurants r on r.id = mi.restaurant_id
      where o.id = menu_item_option_choices.option_id and r.owner_id = auth.uid()
    )
  );
