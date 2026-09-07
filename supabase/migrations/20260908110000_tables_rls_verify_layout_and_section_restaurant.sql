-- The original tables INSERT/UPDATE policies (20260907091500_create_tables.sql)
-- only verified that restaurant_id belongs to the caller - they never checked
-- that layout_id/section_id actually belong to that same restaurant. An owner
-- could insert (or update) a table with their own restaurant_id but another
-- owner's layout_id/section_id, silently attaching one restaurant's table to
-- another restaurant's layout or section. layouts/sections ids aren't secret
-- (both have "any authenticated user can view" select policies, same as
-- every other table in this app), so this is reachable today via a direct
-- API call, not just theoretical - though its current blast radius is small
-- since every read path in the app scopes tables by restaurant_id first, so
-- a poisoned row just becomes an orphaned row under the attacker's own
-- restaurant. Recreate both policies with the missing cross-table checks.
--
-- tables.restaurant_id/layout_id/section_id are qualified explicitly below -
-- bare column names in the nested EXISTS clauses would resolve to the
-- subquery's own layouts/sections.restaurant_id column instead (both tables
-- have one), silently turning the check into the tautology
-- `l.restaurant_id = l.restaurant_id` rather than comparing against the row
-- being inserted/updated.
drop policy "Owners can add tables to their own restaurants" on public.tables;
drop policy "Owners can update their own restaurant tables" on public.tables;

create policy "Owners can add tables to their own restaurants"
  on public.tables for insert
  to authenticated
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = tables.restaurant_id and r.owner_id = auth.uid()
    )
    and exists (
      select 1 from public.layouts l
      where l.id = tables.layout_id and l.restaurant_id = tables.restaurant_id
    )
    and (
      tables.section_id is null
      or exists (
        select 1 from public.sections s
        where s.id = tables.section_id and s.restaurant_id = tables.restaurant_id
      )
    )
  );

create policy "Owners can update their own restaurant tables"
  on public.tables for update
  to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = tables.restaurant_id and r.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = tables.restaurant_id and r.owner_id = auth.uid()
    )
    and exists (
      select 1 from public.layouts l
      where l.id = tables.layout_id and l.restaurant_id = tables.restaurant_id
    )
    and (
      tables.section_id is null
      or exists (
        select 1 from public.sections s
        where s.id = tables.section_id and s.restaurant_id = tables.restaurant_id
      )
    )
  );
