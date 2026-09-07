-- Once a restaurant has a table layout, a section's capacity is derived
-- from its assigned tables' seats - a brand new section with no tables
-- assigned to it yet legitimately has capacity 0 (not yet a positive
-- number the owner types), so the original "> 0" constraint is too strict
-- for that state.
alter table public.sections
  drop constraint sections_capacity_positive,
  add constraint sections_capacity_positive check (capacity >= 0);
