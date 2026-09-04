-- Restaurant sections (e.g. smoking/non-smoking, indoor/outdoor) that a
-- customer can optionally pick when reserving. Independent of the table
-- layout feature (not built yet) - a restaurant can have sections without
-- a layout, a layout without sections, both, or neither.
--
-- capacity is manually typed by the owner here. Once the table layout
-- feature exists, a section's *effective* capacity becomes derived from
-- its assigned tables' seats instead - that's handled entirely in
-- application code (computed on read, nothing stored/triggered), so this
-- column's stored value is simply left stale/ignored at that point rather
-- than needing a schema change. Same for restaurants.capacity: once this
-- restaurant has any section, its effective capacity is computed as
-- sum(sections.capacity) in application code rather than trusting the
-- stored restaurants.capacity column - that column is only written back to
-- (seeded with the last computed sum) when the owner deletes their last
-- remaining section, unfreezing it back to a manually-typed value.
--
-- No default/catch-all section - deliberately out of scope until the table
-- layout feature exists to give it something concrete to mean.
create table public.sections (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  name text not null,
  capacity integer not null,
  created_at timestamptz not null default now(),
  constraint sections_capacity_positive check (capacity > 0),
  unique (restaurant_id, name)
);

create index sections_restaurant_id_idx on public.sections (restaurant_id);

alter table public.sections enable row level security;

-- Explicit grants: this project has "automatically expose new tables"
-- disabled, so nothing is reachable via the Data API until granted here.
grant select, insert, update, delete on public.sections to authenticated;

-- Same public-read shape as restaurants/restaurant_hours - customers and
-- employees will need to read sections later (e.g. to pick one when
-- reserving).
create policy "Authenticated users can view sections"
  on public.sections for select
  to authenticated
  using (true);

create policy "Owners can add sections to their own restaurants"
  on public.sections for insert
  to authenticated
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can update their own restaurant sections"
  on public.sections for update
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

create policy "Owners can delete their own restaurant sections"
  on public.sections for delete
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );
