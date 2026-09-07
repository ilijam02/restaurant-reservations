-- A restaurant can now have several layouts active at once (e.g. one per
-- floor) instead of a single "current" one - capacity is derived from the
-- union of every active layout's tables. Since a layout already belongs to
-- exactly one restaurant, "active" is just a flag on the layout itself, not
-- a separate join table.
alter table public.layouts
  add column is_active boolean not null default false;

update public.layouts l
set is_active = true
from public.restaurants r
where r.current_layout_id = l.id;

alter table public.restaurants
  drop column current_layout_id;
