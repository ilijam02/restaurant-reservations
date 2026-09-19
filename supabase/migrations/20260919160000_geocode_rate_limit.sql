-- App-wide throttle for the public Nominatim geocoder (see src/lib/geocode.ts).
-- Its usage policy allows at most 1 request per second per client, and this
-- app is one client no matter how many owners are searching. Owner accounts
-- are free to create, so a per-user limit wouldn't stop one person looping
-- through accounts; a single global slot does: whoever loses the race is told
-- to retry, and the worst an abuser can do is slow geocoding down for others,
-- never get the server's IP blocked.
--
-- One row, enforced by the `id boolean primary key check (id)` trick. It lives
-- in the database rather than server memory so it holds across restarts and
-- across however many server instances end up running.
create table public.geocode_rate_limit (
  id boolean primary key default true check (id),
  last_call_at timestamptz not null default '-infinity'
);

insert into public.geocode_rate_limit (id) values (true);

-- Reachable only through claim_geocode_slot(): RLS on with no policies, and
-- an explicit revoke. The hosted project doesn't auto-expose new tables, but a
-- local stack (and CI) grants them to anon/authenticated by default, so the
-- revoke keeps "permission denied" true in every environment rather than
-- leaning on whichever defaults happen to be in force.
alter table public.geocode_rate_limit enable row level security;
revoke all on table public.geocode_rate_limit from public, anon, authenticated;

-- Returns true when the caller may make one geocoding request now (and records
-- that they did), false when someone else has used the slot within the last
-- 1.1 seconds. The single UPDATE ... WHERE is atomic: concurrent callers
-- serialize on the row lock, and the loser re-checks the WHERE against the
-- winner's committed value and matches nothing. Owner-role accounts only,
-- matching who the geocoding action itself serves - checked here too because
-- this is callable straight from the Data API, not just through that action.
-- security definer because authenticated has no grant on the table at all.
create function public.claim_geocode_slot()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claimed boolean;
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles where id = auth.uid() and role = 'owner'
  ) then
    return false;
  end if;

  -- 1.1s rather than 1s: a little slack over the policy's limit for clock
  -- differences between us and their server.
  update public.geocode_rate_limit
  set last_call_at = clock_timestamp()
  where id and last_call_at <= clock_timestamp() - interval '1100 milliseconds'
  returning true into v_claimed;

  return coalesce(v_claimed, false);
end;
$$;

revoke all on function public.claim_geocode_slot() from public, anon;
grant execute on function public.claim_geocode_slot() to authenticated;
