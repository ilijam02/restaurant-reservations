-- Mirrors get_occupied_table_ids.sql, but for the no-layout/sections-only
-- world: lets a customer see a section's remaining room for a candidate
-- time range before submitting, so the form can warn them up front that an
-- explicit section preference won't fit the whole party - create_reservation()
-- rejects that outright rather than spilling into another section, so
-- catching it client-side (instead of only after a failed submit) is the
-- whole point here.
--
-- Same privacy shape as get_occupied_table_ids: reservation_sections/
-- reservations are only selectable by the reservation's own customer, the
-- restaurant's owner, or accepted staff, so a browsing customer can't
-- otherwise compute this. Only a capacity number is returned - no
-- reservation identity.
create or replace function public.get_section_remaining_capacity(
  p_restaurant_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz
)
returns table (section_id uuid, remaining integer)
language sql
stable
security definer
set search_path = ''
as $$
  select
    s.id,
    greatest(0, s.capacity - coalesce((
      select sum(rs.party_size) from public.reservation_sections rs
      join public.reservations r on r.id = rs.reservation_id
      where rs.section_id = s.id
        and r.status = 'confirmed'
        and tstzrange(r.starts_at, r.ends_at) && tstzrange(p_starts_at, p_ends_at)
    ), 0))::integer
  from public.sections s
  where s.restaurant_id = p_restaurant_id;
$$;

grant execute on function public.get_section_remaining_capacity(uuid, timestamptz, timestamptz) to authenticated;
