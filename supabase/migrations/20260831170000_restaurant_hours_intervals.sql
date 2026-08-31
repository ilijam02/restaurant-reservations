-- Replace the flag-based working-hours model (open_time/close_time plus
-- is_24h/closes_next_day) with plain intervals: start_minute/end_minute
-- (minutes since midnight, 0-1440) and multiple rows per day allowed. This
-- is what makes a drag-to-select weekly calendar UI work without any of
-- the special-case flags or their validation: every row is a same-day
-- interval with end > start by construction, split shifts are just extra
-- rows, 24h is a full 0..1440 row, and overnight is two adjacent rows in
-- neighboring day columns. smallint minute-offsets are used instead of
-- Postgres `time` specifically because `time` cannot represent 24:00 (its
-- max is 23:59:59), which is needed for a block running to exact midnight.
alter table public.restaurant_hours
  add column start_minute smallint,
  add column end_minute smallint;

-- Drop the old constraints up front, before reshaping the data below - the
-- unique(restaurant_id, day_of_week) constraint in particular would block
-- the overnight split (which adds a second row for a day that may already
-- have one), and the old check constraints don't apply to the new columns
-- anyway.
alter table public.restaurant_hours
  drop constraint restaurant_hours_open_close_together,
  drop constraint restaurant_hours_24h_no_times,
  drop constraint restaurant_hours_close_after_open,
  drop constraint restaurant_hours_restaurant_id_day_of_week_key;

-- 24h rows (open_time/close_time are null for these, per the old
-- restaurant_hours_24h_no_times constraint) become a full-day block.
update public.restaurant_hours
set start_minute = 0, end_minute = 1440
where is_24h;

-- Overnight rows split into two: the existing row becomes the "today"
-- portion (open time through midnight); a new row is inserted for the
-- "tomorrow" portion (midnight through close time) on the following
-- day_of_week. The insert reads the original open_time/close_time before
-- the update below overwrites them, so it must run first.
insert into public.restaurant_hours
  (restaurant_id, day_of_week, open_time, close_time, is_24h, closes_next_day, start_minute, end_minute)
select
  restaurant_id,
  (day_of_week + 1) % 7,
  null, null, false, false,
  0,
  extract(hour from close_time)::int * 60 + extract(minute from close_time)::int
from public.restaurant_hours
where closes_next_day and not is_24h and open_time is not null and close_time is not null;

update public.restaurant_hours
set start_minute = extract(hour from open_time)::int * 60 + extract(minute from open_time)::int,
    end_minute = 1440
where closes_next_day and not is_24h and open_time is not null and close_time is not null;

-- Ordinary same-day rows.
update public.restaurant_hours
set start_minute = extract(hour from open_time)::int * 60 + extract(minute from open_time)::int,
    end_minute = extract(hour from close_time)::int * 60 + extract(minute from close_time)::int
where not is_24h and not closes_next_day and open_time is not null and close_time is not null;

-- Legacy "closed day" rows (null open/close, not 24h) have no interval to
-- represent - in the new model "closed" is just the absence of a row for
-- that day, so drop them rather than converting.
delete from public.restaurant_hours
where start_minute is null or end_minute is null;

alter table public.restaurant_hours
  alter column start_minute set not null,
  alter column end_minute set not null,
  drop column open_time,
  drop column close_time,
  drop column is_24h,
  drop column closes_next_day;

alter table public.restaurant_hours
  add constraint restaurant_hours_range_valid
    check (start_minute >= 0 and end_minute > start_minute and end_minute <= 1440);
