-- Physical tables on a restaurant's floor plan. Optional feature,
-- independent of sections (see the "Restaurant sections & table layout"
-- decisions in ISSUES.md) - a restaurant can have a layout without
-- sections, sections without a layout, both, or neither.
--
-- section_id is nullable at the DB level even once the restaurant has
-- sections - the "every table must belong to a section once any section
-- exists" rule is enforced entirely in app logic (never a DB constraint,
-- and the app never actually writes a table in a violating state), same
-- pattern as sections' own structural rules. on delete set null (not
-- cascade): deleting a section must not delete the tables that were in
-- it - they become unassigned instead, which the app only allows when no
-- other sections remain (otherwise it blocks the section delete and asks
-- the owner to reassign those tables first).
--
-- x/y/width/height are plain integers in grid units (the owner-facing
-- canvas snaps to a grid) - no shape or rotation column, since every
-- table renders as a plain axis-aligned rectangle.
create table public.tables (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  section_id uuid references public.sections (id) on delete set null,
  name text not null,
  seats integer not null,
  x integer not null,
  y integer not null,
  width integer not null,
  height integer not null,
  created_at timestamptz not null default now(),
  constraint tables_seats_positive check (seats > 0),
  constraint tables_width_positive check (width > 0),
  constraint tables_height_positive check (height > 0),
  unique (restaurant_id, name)
);

create index tables_restaurant_id_idx on public.tables (restaurant_id);
create index tables_section_id_idx on public.tables (section_id);

alter table public.tables enable row level security;

-- Explicit grants: this project has "automatically expose new tables"
-- disabled, so nothing is reachable via the Data API until granted here.
grant select, insert, update, delete on public.tables to authenticated;

-- Same public-read shape as sections/restaurant_hours - customers and
-- employees will need to read tables later (e.g. to pick one when
-- reserving).
create policy "Authenticated users can view tables"
  on public.tables for select
  to authenticated
  using (true);

create policy "Owners can add tables to their own restaurants"
  on public.tables for insert
  to authenticated
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can update their own restaurant tables"
  on public.tables for update
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

create policy "Owners can delete their own restaurant tables"
  on public.tables for delete
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );
