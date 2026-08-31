-- Two edge cases the original restaurant_hours design left implicit:
-- restaurants open 24 hours, and restaurants that close after midnight.
-- Both get an explicit flag rather than being inferred from open_time/
-- close_time values (e.g. 00:00-00:00 for "24h") - a checkbox the owner
-- ticks is far less ambiguous than a magic time value.
alter table public.restaurant_hours
  add column is_24h boolean not null default false,
  add column closes_next_day boolean not null default false;

-- Existing rows predate this distinction. The old form had no way to enter
-- "closed" or "24h" as a special value, so any existing row where
-- close_time <= open_time can only have been an attempt at overnight hours -
-- backfill it accordingly instead of leaving it to violate the ordering
-- constraint added below.
update public.restaurant_hours
set closes_next_day = true
where open_time is not null
  and close_time is not null
  and close_time <= open_time;

-- A 24h day has no open/close times and can't also be "closes next day".
alter table public.restaurant_hours
  add constraint restaurant_hours_24h_no_times
    check (not is_24h or (open_time is null and close_time is null and not closes_next_day));

-- For a same-day (not overnight, not 24h) row, closing must be after
-- opening - this is the case flagged as ambiguous/invalid input in the
-- edit form (close time <= open time without the overnight box checked).
alter table public.restaurant_hours
  add constraint restaurant_hours_close_after_open
    check (
      is_24h
      or closes_next_day
      or open_time is null
      or close_time is null
      or close_time > open_time
    );
