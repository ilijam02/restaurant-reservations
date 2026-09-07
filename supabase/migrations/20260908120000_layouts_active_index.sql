-- Composite (not standalone) index: every real query filters by a specific
-- restaurant first (there's no cross-restaurant "all active layouts"
-- lookup), and is_active alone is too low-cardinality to be worth indexing
-- by itself - restaurant_id is already the selective part, is_active just
-- narrows within it (e.g. capacity math for a restaurant's active layouts).
create index layouts_restaurant_id_is_active_idx on public.layouts (restaurant_id, is_active);
