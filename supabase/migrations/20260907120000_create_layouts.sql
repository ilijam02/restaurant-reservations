-- A restaurant can have multiple table layouts (e.g. drafts, seasonal
-- variants) but only one is "current" - the one that actually drives
-- capacity and (later) what customers see. Layouts are otherwise just a
-- name; tables now belong to a specific layout, not directly to a
-- restaurant's undifferentiated table pool.
create table public.layouts (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (restaurant_id, name)
);

create index layouts_restaurant_id_idx on public.layouts (restaurant_id);

alter table public.layouts enable row level security;

grant select, insert, update, delete on public.layouts to authenticated;

create policy "Authenticated users can view layouts"
  on public.layouts for select
  to authenticated
  using (true);

create policy "Owners can add layouts to their own restaurants"
  on public.layouts for insert
  to authenticated
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can update their own restaurant layouts"
  on public.layouts for update
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can delete their own restaurant layouts"
  on public.layouts for delete
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );

-- Give every restaurant that already has tables a default layout, and
-- move those tables onto it, before layout_id is required below.
insert into public.layouts (id, restaurant_id, name)
select gen_random_uuid(), restaurant_id, 'Raspored 1'
from (select distinct restaurant_id from public.tables) as restaurants_with_tables;

alter table public.tables
  add column layout_id uuid references public.layouts (id) on delete cascade;

update public.tables t
set layout_id = l.id
from public.layouts l
where l.restaurant_id = t.restaurant_id and l.name = 'Raspored 1';

alter table public.tables
  alter column layout_id set not null;

create index tables_layout_id_idx on public.tables (layout_id);

-- The restaurant's active layout - null means none chosen yet. set null
-- (not cascade) on the referenced layout's deletion, so removing a layout
-- never removes the restaurant itself.
alter table public.restaurants
  add column current_layout_id uuid references public.layouts (id) on delete set null;

update public.restaurants r
set current_layout_id = l.id
from public.layouts l
where l.restaurant_id = r.id and l.name = 'Raspored 1';
