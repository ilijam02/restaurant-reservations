-- RLS + create_reservation() coverage (see
-- supabase/migrations/20260908130000_create_reservations.sql).
--
-- The test restaurant is given full 24/7 hours (every day_of_week,
-- 00:00-24:00) so every assertion below is about capacity/exclusion
-- behavior, not hours-crossing logic - that's covered by manual browser
-- verification instead (the day/midnight-crossing math isn't worth
-- reproducing here on top of everything else this file already checks).
begin;
select plan(13);

select tests.rls_enabled('public', 'reservations');

select tests.create_supabase_user('owner_a', 'ownera@test.com', null,
  '{"first_name":"Owner","last_name":"A","phone":"555-0001","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_b', 'ownerb@test.com', null,
  '{"first_name":"Owner","last_name":"B","phone":"555-0005","role":"owner"}'::jsonb);
select tests.create_supabase_user('customer_1', 'customer1@test.com', null,
  '{"first_name":"Cust","last_name":"One","phone":"555-0002","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_2', 'customer2@test.com', null,
  '{"first_name":"Cust","last_name":"Two","phone":"555-0003","role":"customer"}'::jsonb);
select tests.create_supabase_user('employee_1', 'employee1@test.com', null,
  '{"first_name":"Emp","last_name":"One","phone":"555-0004","role":"employee"}'::jsonb);
select tests.create_supabase_user('employee_2', 'employee2@test.com', null,
  '{"first_name":"Emp","last_name":"Two","phone":"555-0006","role":"employee"}'::jsonb);

-- Setup (not asserted): a restaurant, open 24/7, with a 4-seat section and
-- a 4-seat table on an active layout, an accepted staff member, and a
-- still-pending one. Plus an unrelated second owner/restaurant to confirm
-- cross-restaurant isolation.
select tests.authenticate_as('owner_a');
insert into public.restaurants (owner_id, name, capacity) values (tests.get_supabase_uid('owner_a'), 'A''s Bistro', 4);
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'A''s Bistro'), d, 0, 1440
  from generate_series(0, 6) as d;
insert into public.sections (restaurant_id, name, capacity, color_index)
  values ((select id from public.restaurants where name = 'A''s Bistro'), 'Glavna sala', 4, 0);
insert into public.layouts (restaurant_id, name, is_active)
  values ((select id from public.restaurants where name = 'A''s Bistro'), 'Raspored 1', true);
insert into public.tables (restaurant_id, layout_id, section_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'A''s Bistro'),
    (select id from public.layouts where name = 'Raspored 1'),
    (select id from public.sections where name = 'Glavna sala'),
    'Sto 1', 4, 0, 0, 2, 2
  );
insert into public.restaurant_staff (restaurant_id, employee_id, status)
  values ((select id from public.restaurants where name = 'A''s Bistro'), tests.get_supabase_uid('employee_1'), 'accepted');
insert into public.restaurant_staff (restaurant_id, employee_id, status)
  values ((select id from public.restaurants where name = 'A''s Bistro'), tests.get_supabase_uid('employee_2'), 'pending');

select tests.authenticate_as('owner_b');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_b'), 'B''s Diner');

-- Customer 1 books the table for tomorrow at noon.
select tests.authenticate_as('customer_1');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '1 day 12 hours')
    )$$,
  'customer_1 can book a restaurant-level reservation'
);

-- A direct insert bypassing the RPC is rejected - no insert grant at all.
select throws_ok(
  $$insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at)
    values (
      (select id from public.restaurants where name = 'A''s Bistro'),
      tests.get_supabase_uid('customer_1'),
      2,
      now() + interval '1 day',
      now() + interval '1 day 1 hour'
    )$$,
  '42501',
  null,
  'direct insert into reservations bypassing create_reservation() is rejected'
);

-- Customer 1 sees their own reservation; customer 2 does not.
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1')$$,
  ARRAY[1],
  'customer_1 can see their own reservation'
);

select tests.authenticate_as('customer_2');
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1')$$,
  ARRAY[0],
  'customer_2 cannot see customer_1''s reservation'
);

-- The owner and an accepted staff member can both see it.
select tests.authenticate_as('owner_a');
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1')$$,
  ARRAY[1],
  'the restaurant''s owner can see the reservation'
);

select tests.authenticate_as('employee_1');
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1')$$,
  ARRAY[1],
  'an accepted staff member can see the reservation'
);

-- A still-pending staff member cannot - the policy explicitly requires
-- status = 'accepted'.
select tests.authenticate_as('employee_2');
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1')$$,
  ARRAY[0],
  'a pending (not yet accepted) staff member cannot see the reservation'
);

-- An unrelated owner of a different restaurant cannot see it either.
select tests.authenticate_as('owner_b');
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1')$$,
  ARRAY[0],
  'an unrelated owner cannot see another restaurant''s reservation'
);

-- Customer 2 books the table (still empty) at a different, non-overlapping
-- time - should succeed.
select tests.authenticate_as('customer_2');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '2 days 12 hours'),
      60,
      null,
      (select id from public.tables where name = 'Sto 1')
    )$$,
  'customer_2 can book the table on a different day'
);

-- Booking the same table over an overlapping range fails via the exclusion
-- constraint, surfaced as a friendly message.
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '2 days 12 hours 30 minutes'),
      60,
      null,
      (select id from public.tables where name = 'Sto 1')
    )$$,
  'P0001',
  'Sto je već rezervisan u to vreme.',
  'double-booking the same table over an overlapping range is rejected'
);

-- The restaurant's own capacity is 4; two more guests already booked
-- restaurant-level at day+1 noon (customer_1, above) leaves no room for a
-- party of 4 at the same time.
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      4,
      (date_trunc('day', now()) + interval '1 day 12 hours')
    )$$,
  'P0001',
  'Nema dovoljno slobodnih mesta u izabrano vreme.',
  'booking past the restaurant''s effective capacity is rejected'
);

-- A party of 3 fits in the remaining 2 seats? No - still rejected (only 2
-- of the 4-seat capacity remain after customer_1's party of 2).
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      3,
      (date_trunc('day', now()) + interval '1 day 12 hours')
    )$$,
  'P0001',
  'Nema dovoljno slobodnih mesta u izabrano vreme.',
  'a party that would exceed remaining restaurant capacity is rejected'
);

select * from finish();
rollback;
