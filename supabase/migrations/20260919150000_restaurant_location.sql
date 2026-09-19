-- Where a restaurant is, for the customer map. All three columns are nullable:
-- existing restaurants (and new ones, until an owner fills the location in)
-- simply don't appear on the map. `address` is the owner's free text; the
-- coordinates are what the map actually draws, and the owner can nudge them
-- by hand after a geocode, so the two are stored independently and neither is
-- derived from the other. Plain double precision rather than PostGIS - the map
-- only draws pins, there are no distance queries yet.
--
-- No RLS or grant changes: restaurants is already readable by any
-- authenticated user and writable only by its owner, which is exactly the
-- access these columns need (its grants are table-wide, not column-level).
alter table public.restaurants
  add column address text,
  add column latitude double precision,
  add column longitude double precision;

-- A pin needs both coordinates or neither, and they have to be real ones.
alter table public.restaurants
  add constraint restaurants_location_together
    check ((latitude is null) = (longitude is null)),
  add constraint restaurants_latitude_range
    check (latitude is null or latitude between -90 and 90),
  add constraint restaurants_longitude_range
    check (longitude is null or longitude between -180 and 180),
  add constraint restaurants_address_not_blank
    check (address is null or length(btrim(address)) > 0);
