-- create_reservation() enforces a 30-180 minute reservation duration, but
-- when a customer leaves "Trajanje (min)" blank it falls back to
-- restaurants.default_stay_minutes - previously only constrained to be
-- positive, so an owner could set a default outside 30-180 and make that
-- fallback path (the common case) permanently rejected with a confusing
-- error the customer never chose to trigger.
alter table public.restaurants
  drop constraint restaurants_default_stay_minutes_positive;

alter table public.restaurants
  add constraint restaurants_default_stay_minutes_range
    check (default_stay_minutes between 30 and 180);
