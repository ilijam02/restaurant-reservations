-- Lets a customer see which tables are already booked for a candidate
-- time range *before* submitting a reservation, so the table picker can
-- show free/occupied borders and block picking an occupied table.
--
-- reservation_tables/reservations are only selectable by the reservation's
-- own customer, the restaurant's owner, or its accepted staff - a browsing
-- customer is none of those for someone else's booking, so a plain select
-- can't answer "is this table free?" without leaking whose reservation it
-- is anyway. This function returns only the occupied table ids (security
-- definer, so it can read reservation_tables despite RLS) - no reservation
-- identity or customer info leaves it.
create or replace function public.get_occupied_table_ids(
  p_restaurant_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz
)
returns table (table_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct rt.table_id
  from public.reservation_tables rt
  join public.reservations r on r.id = rt.reservation_id
  join public.tables t on t.id = rt.table_id
  where t.restaurant_id = p_restaurant_id
    and r.status = 'confirmed'
    and tstzrange(rt.starts_at, rt.ends_at) && tstzrange(p_starts_at, p_ends_at);
$$;

grant execute on function public.get_occupied_table_ids(uuid, timestamptz, timestamptz) to authenticated;
