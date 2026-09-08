-- Mirrors get_occupied_table_ids.sql, but for the no-layout/sections-only
-- world: lets a customer see a section's remaining room for a candidate
-- time range before submitting, so the form can preview up front how many
-- guests would spill into another section if an explicit section
-- preference doesn't have room for the whole party - create_reservation()
-- fills the preferred section first, then spills the remainder into other
-- sections by remaining capacity, so this is a "how much would spill"
-- preview, not a "will this be rejected" one.
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
