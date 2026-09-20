-- Restaurant names are unique across the app (customers find restaurants by
-- name, and two identical entries in the browse list or on the map are
-- indistinguishable).
--
-- Two choices worth knowing about:
--   * Case- and whitespace-insensitive: "Pica Napoli", "pica napoli" and
--     " Pica Napoli " are the same name. A plain unique(name) would let an
--     owner create a look-alike that differs only by a capital letter.
--   * Only live restaurants count (archived_at is null). An archived restaurant
--     is invisible to everyone and can never come back (there is no restore),
--     but it keeps its row - and so its name - for its customers' reservation
--     history (see delete_restaurant()). If archived rows held the name, an
--     owner who "deleted" a restaurant could never reuse its name and would
--     have no way to see why it is taken.
--
-- A partial index on an expression can't be written as a table-level UNIQUE
-- constraint, so this is a unique index; it enforces exactly the same thing
-- and raises the same 23505 unique_violation, which the create/edit forms map
-- to a readable message by this index's name.
create unique index restaurants_live_name_unique_idx
  on public.restaurants (lower(btrim(name)))
  where archived_at is null;
