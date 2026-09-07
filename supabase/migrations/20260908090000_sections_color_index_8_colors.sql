-- The section color palette shrank from 32 to 8 - wrap any existing
-- color_index into the new range (mod 8) so the constraint below can be
-- tightened to match, same "least-used index wins, ties break low" scheme
-- just over a smaller palette.
update public.sections
set color_index = color_index % 8;

alter table public.sections
  drop constraint sections_color_index_range,
  add constraint sections_color_index_range check (color_index between 0 and 7);
