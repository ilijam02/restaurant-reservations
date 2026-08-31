-- Groundwork for the reservation feature: lets an owner set a hard capacity
-- cap and a default reservation duration before the full table-layout
-- feature exists, plus fully customizable per-day working hours.
alter table public.restaurants
  add column capacity integer,
  add column default_stay_minutes integer not null default 90;

alter table public.restaurants
  add constraint restaurants_capacity_positive
    check (capacity is null or capacity > 0),
  add constraint restaurants_default_stay_minutes_positive
    check (default_stay_minutes > 0);

-- One row per day of the week. day_of_week follows Postgres's own
-- extract(dow from ...) convention (0 = Sunday .. 6 = Saturday) so the
-- reservation feature can later join straight against a booking's date
-- without translating conventions; the edit UI just displays/orders the
-- days Monday-first for the owner.
--
-- open_time/close_time are both null together to mean "closed that day" -
-- not used by the current edit UI (which always fills all 14 fields), but
-- left nullable so a "closed on Sundays" toggle can be added later without
-- a schema change. Overnight hours (e.g. open 18:00, close 02:00) are not
-- validated against each other here - deferred until a restaurant actually
-- needs it.
create table public.restaurant_hours (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 0 and 6),
  open_time time,
  close_time time,
  constraint restaurant_hours_open_close_together
    check ((open_time is null) = (close_time is null)),
  unique (restaurant_id, day_of_week)
);

create index restaurant_hours_restaurant_id_idx on public.restaurant_hours (restaurant_id);

alter table public.restaurant_hours enable row level security;

-- Explicit grants: this project has "automatically expose new tables"
-- disabled, so nothing is reachable via the Data API until granted here.
grant select, insert, update, delete on public.restaurant_hours to authenticated;

-- Same public-read shape as restaurants itself - customers/employees will
-- need to read hours later (e.g. to show "open now" or validate a booking).
create policy "Authenticated users can view restaurant hours"
  on public.restaurant_hours for select
  to authenticated
  using (true);

create policy "Owners can add hours to their own restaurants"
  on public.restaurant_hours for insert
  to authenticated
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );

create policy "Owners can update their own restaurant hours"
  on public.restaurant_hours for update
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

create policy "Owners can delete their own restaurant hours"
  on public.restaurant_hours for delete
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_id and r.owner_id = auth.uid()
    )
  );
