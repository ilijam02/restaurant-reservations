-- Table names don't need to be unique within a restaurant - unlike
-- sections, two tables legitimately might share a label (or the owner just
-- doesn't care to keep them distinct). This also removes the need for the
-- temp-rename-before-final-rename dance the app was doing purely to dodge
-- transient collisions on this constraint when swapping two tables' names.
alter table public.tables
  drop constraint tables_restaurant_id_name_key;
