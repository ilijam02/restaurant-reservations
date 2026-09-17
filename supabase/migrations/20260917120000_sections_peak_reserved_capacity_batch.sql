-- Follow-up to 20260913140000_protect_capacity_from_active_reservations.sql,
-- prompted by a real bug it exposed: the owner's edit form saves a changed
-- section by first renaming it to a guaranteed-unique "__tmp_<id>"
-- placeholder (to avoid transiently colliding with another section being
-- renamed in the same save), then a second statement sets the real name
-- *and* capacity together. If that second statement is now rejected by
-- prevent_section_capacity_below_reserved(), the first (temp-rename)
-- statement already committed and nothing rolls it back - the section is
-- left stuck on its "__tmp_<id>" name even though the owner only touched
-- capacity, not the name.
--
-- Fix: the form now pre-checks every section whose capacity is decreasing
-- *before* the temp-rename dance starts at all, the same way it already
-- pre-checks deletions. This function is what that pre-check calls - given
-- a set of section ids, report each one's own peak reserved capacity in one
-- round trip (batched, like tables_with_active_reservations()), so a single
-- save can name every section that would fail, not just the first.
create or replace function public.sections_peak_reserved_capacity(p_section_ids uuid[])
returns table (section_id uuid, section_name text, peak_capacity integer)
language sql
security definer
set search_path = ''
stable
as $$
  select s.id, s.name, public.section_peak_reserved_capacity(s.id)
  from public.sections s
  where s.id = any(p_section_ids);
$$;

grant execute on function public.sections_peak_reserved_capacity(uuid[]) to authenticated;
