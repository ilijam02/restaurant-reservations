-- Table names are only unique per layout, not per restaurant (see
-- tables_layout_name_unique.sql) - so once a save spans more than one
-- layout (the owner's edit form gathers blocked tables across every
-- layout being touched, not just the one open on the canvas), a flat list
-- of table names in the "which tables block this save" error can be
-- ambiguous: two different layouts can each have their own "Sto 1".
-- tables_with_active_reservations() now also returns which layout each
-- blocked table belongs to, so the owner's edit form can group by layout
-- when more than one is involved. Return type changed, so the old function
-- has to be dropped first rather than `create or replace` (which only
-- works for an unchanged column list) - no other caller exists yet besides
-- the owner form's pre-check, so nothing else is affected.
drop function if exists public.tables_with_active_reservations(uuid[]);

create function public.tables_with_active_reservations(p_table_ids uuid[])
returns table (table_id uuid, table_name text, layout_name text, starts_at timestamptz, party_size integer)
language sql
security definer
set search_path = ''
stable
as $$
  select distinct on (t.id) t.id, t.name, l.name, r.starts_at, r.party_size
  from public.tables t
  join public.layouts l on l.id = t.layout_id
  join public.reservation_tables rt on rt.table_id = t.id
  join public.reservations r on r.id = rt.reservation_id
  where t.id = any(p_table_ids)
    and r.status = 'confirmed'
    and r.ends_at >= now()
  order by t.id, r.starts_at;
$$;

grant execute on function public.tables_with_active_reservations(uuid[]) to authenticated;
