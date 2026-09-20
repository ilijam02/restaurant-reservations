-- Behavioral signals for the recommendation algorithm (ISSUES.md: "Rank
-- browsed restaurants by ML recommendation algorithm").
--
-- The algorithm is collaborative: it learns from what customers *do*. Bookings
-- are already in `reservations` (and get by far the biggest weight), so this
-- adds the two cheaper signals that let a new customer leave the cold start
-- without having to book first:
--   * favorites         - an explicit "I like this", a toggle (one row per pair)
--   * restaurant_views  - how often a customer opened a restaurant's page, kept
--                         as a counter + last-viewed time, not one row per view
--                         (bounded growth; the scoring caps a pair's total view
--                         contribution well below a single booking, so the exact
--                         count past a handful never matters)
--
-- Both belong to the customer and to nobody else: no other user, owner or
-- staff member can read them, and they are deleted with the account. That is
-- the opposite of reservations/orders, which stay behind anonymized because a
-- restaurant's history is worth keeping - a private browsing trail isn't. So
-- both foreign keys to auth.users are ON DELETE CASCADE and delete_my_account()
-- needs no change: deleting the auth.users row removes them. (The
-- recommendation function that reads across users, added later, is
-- security definer and returns only restaurant ids and scores - never anyone
-- else's behavior.)
--
-- Both cascade from restaurants too. A restaurant that is *archived* keeps its
-- rows (archiving is an update, not a delete); every reader has to filter
-- `archived_at is null`, same as any other restaurant listing.

create table public.favorites (
  user_id uuid not null references auth.users (id) on delete cascade,
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, restaurant_id)
);

-- The primary key serves per-user lookups; the recommender also scans by
-- restaurant (popularity, "who else favorited this"), and the cascade from
-- restaurants needs it too.
create index favorites_restaurant_id_idx on public.favorites (restaurant_id);

create table public.restaurant_views (
  user_id uuid not null references auth.users (id) on delete cascade,
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  view_count integer not null default 1 check (view_count > 0),
  last_viewed_at timestamptz not null default now(),
  primary key (user_id, restaurant_id)
);

create index restaurant_views_restaurant_id_idx on public.restaurant_views (restaurant_id);

alter table public.favorites enable row level security;
alter table public.restaurant_views enable row level security;

-- Explicit revokes first: a local stack (and CI) grants new tables to
-- anon/authenticated by default, the hosted project doesn't, and the grants
-- below should be the only ones in every environment.
revoke all on table public.favorites from public, anon, authenticated;
revoke all on table public.restaurant_views from public, anon, authenticated;

-- favorites: plain owner-write. A favorite is one row the customer adds or
-- removes, with nothing to validate beyond "yours, and you're a customer, and
-- the restaurant isn't archived" - so no RPC, just RLS and one trigger.
-- There is no update grant: a favorite has no editable column.
grant select, insert, delete on public.favorites to authenticated;

create policy "Customers can view their own favorites"
  on public.favorites for select
  to authenticated
  using (user_id = auth.uid());

create policy "Customers can add their own favorites"
  on public.favorites for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.profiles where id = auth.uid() and role = 'customer')
  );

create policy "Customers can remove their own favorites"
  on public.favorites for delete
  to authenticated
  using (user_id = auth.uid());

-- Reuses the guard from delete_restaurant.sql: no new favorite on an archived
-- restaurant (it's invisible to customers, so it could only come from a stale
-- page or a hand-made request).
create trigger favorites_prevent_insert_for_archived_restaurant
  before insert on public.favorites
  for each row execute function public.prevent_insert_for_archived_restaurant();

-- restaurant_views: select-only for the owner of the row; every write goes
-- through record_restaurant_view(), because an upsert that increments a
-- counter is exactly what a plain insert/update RLS policy can't express (and
-- a client with an update grant could set view_count to anything).
grant select on public.restaurant_views to authenticated;

create policy "Customers can view their own restaurant views"
  on public.restaurant_views for select
  to authenticated
  using (user_id = auth.uid());

-- Records that the caller opened a restaurant's page: creates the row, or bumps
-- its counter and last-viewed time. Deliberately not deduplicated by time
-- window - a refresh counts - because the scoring caps a pair's view
-- contribution, so spamming it can't outweigh a booking, and a window would
-- only make the effect of viewing harder to see. Customer accounts only, and
-- only for a restaurant that exists and isn't archived (a wrong id and an
-- archived one give the same error, like everywhere else). security definer
-- because authenticated has no insert/update grant on the table.
create function public.record_restaurant_view(p_restaurant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'customer') then
    raise exception 'Samo nalozi tipa kupac mogu pregledati restorane.';
  end if;

  if not exists (
    select 1 from public.restaurants where id = p_restaurant_id and archived_at is null
  ) then
    raise exception 'Restoran ne postoji.';
  end if;

  insert into public.restaurant_views (user_id, restaurant_id)
  values (auth.uid(), p_restaurant_id)
  on conflict (user_id, restaurant_id) do update
    set view_count = public.restaurant_views.view_count + 1,
        last_viewed_at = now();
end;
$$;

revoke all on function public.record_restaurant_view(uuid) from public, anon;
grant execute on function public.record_restaurant_view(uuid) to authenticated;
