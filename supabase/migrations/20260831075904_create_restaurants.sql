-- Minimal restaurant record: just enough for an owner to have restaurants
-- to attach later features (menu, sections, table layout, reservations) to.
-- Deliberately no image/address/hours/description yet - those get added
-- (as nullable columns, backfilled, then constrained if needed) when the
-- feature that actually needs them is built, not speculatively now.
-- An owner can have more than one restaurant, so owner_id is a plain
-- indexed foreign key, not unique.
create table public.restaurants (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

create index restaurants_owner_id_idx on public.restaurants (owner_id);

alter table public.restaurants enable row level security;

-- Explicit grants: this project has "automatically expose new tables"
-- disabled, so nothing is reachable via the Data API until granted here.
grant select, insert, update, delete on public.restaurants to authenticated;

create policy "Owners can view their own restaurants"
  on public.restaurants for select
  to authenticated
  using (auth.uid() = owner_id);

-- Restaurant creation is further restricted to accounts with role = 'owner'
-- (not just any authenticated user), matching the project's role-based
-- account types - a customer or employee account can never own a restaurant
-- even if they somehow guessed another user's id.
create policy "Owner-role accounts can create restaurants"
  on public.restaurants for insert
  to authenticated
  with check (
    auth.uid() = owner_id
    and exists (
      select 1 from public.profiles
      where id = auth.uid() and role = 'owner'
    )
  );

create policy "Owners can update their own restaurants"
  on public.restaurants for update
  to authenticated
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

create policy "Owners can delete their own restaurants"
  on public.restaurants for delete
  to authenticated
  using (auth.uid() = owner_id);
