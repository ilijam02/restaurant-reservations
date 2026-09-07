-- Sections get a color for the (not-yet-built) table layout canvas, so a
-- table can be tinted by which section it belongs to. Colors are picked
-- automatically from a fixed 32-color palette owned entirely by app code
-- (src/lib/section-colors.ts) - only the index into that palette is stored,
-- never a literal color value, so the actual hues can be retuned later
-- without touching data. Assignment is "least-used index wins, ties break
-- to the lowest index" (app-computed at section-creation time) rather than
-- a simple used/unused flag, so that once every color has been used at
-- least once, further sections cycle evenly through the palette instead of
-- piling onto index 0 - and a deleted section's freed-up index is the
-- unique least-used one, so the next new section reclaims it immediately.
alter table public.sections
  add column color_index smallint;

-- Backfill existing rows: assign 0, 1, 2, ... per restaurant in creation
-- order, mod 32. Equivalent to the "least-used" rule for a first pass with
-- no deletions yet, which is all this one-off backfill needs to handle.
with ranked as (
  select id, (row_number() over (partition by restaurant_id order by created_at) - 1) % 32 as idx
  from public.sections
)
update public.sections s
set color_index = ranked.idx
from ranked
where s.id = ranked.id;

alter table public.sections
  alter column color_index set not null,
  add constraint sections_color_index_range check (color_index between 0 and 31);
