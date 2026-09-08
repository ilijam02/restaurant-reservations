-- Table names don't need to be unique restaurant-wide (see
-- tables_name_not_unique.sql), but two tables in the *same* layout sharing a
-- name would make the reservation confirmation message
-- ("Layout: table names...") ambiguous about which physical table was
-- actually assigned - so uniqueness is scoped to layout_id instead.
alter table public.tables
  add constraint tables_layout_id_name_key unique (layout_id, name);
