-- RLS + create_reservation() coverage (see
-- supabase/migrations/20260908130000_create_reservations.sql).
--
-- Three restaurants exercise the three distinct capacity/assignment
-- branches: "A's Bistro" has an active layout (table auto-assign +
-- explicit multi-table booking), "C's Cafe" has sections only, no layout
-- (section auto-split), "D's Grill" has neither (the original plain
-- restaurants.capacity baseline). All three get full 24/7 hours so every
-- assertion below is about capacity/assignment/exclusion behavior, not
-- hours-crossing logic - that's covered by manual browser verification
-- instead.
begin;
select plan(31);

select tests.rls_enabled('public', 'reservations');
select tests.rls_enabled('public', 'reservation_tables');
select tests.rls_enabled('public', 'reservation_sections');

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

-- Setup (not asserted): A's Bistro - active layout, two tables in one
-- section.
select tests.authenticate_as('owner_a');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_a'), 'A''s Bistro');
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'A''s Bistro'), d, 0, 1440
  from generate_series(0, 6) as d;
insert into public.sections (restaurant_id, name, capacity, color_index)
  values ((select id from public.restaurants where name = 'A''s Bistro'), 'Glavna sala', 99, 0);
insert into public.layouts (restaurant_id, name, is_active)
  values ((select id from public.restaurants where name = 'A''s Bistro'), 'Raspored 1', true);
insert into public.tables (restaurant_id, layout_id, section_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'A''s Bistro'),
    (select id from public.layouts where name = 'Raspored 1'),
    (select id from public.sections where name = 'Glavna sala'),
    'Sto Mali', 2, 0, 0, 2, 2
  );
insert into public.tables (restaurant_id, layout_id, section_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'A''s Bistro'),
    (select id from public.layouts where name = 'Raspored 1'),
    (select id from public.sections where name = 'Glavna sala'),
    'Sto Veliki', 6, 4, 0, 2, 2
  );
-- employee_1 is accepted staff (can see A's Bistro's reservations),
-- employee_2 is still pending (cannot).
insert into public.restaurant_staff (restaurant_id, employee_id, status)
  values ((select id from public.restaurants where name = 'A''s Bistro'), tests.get_supabase_uid('employee_1'), 'accepted');
insert into public.restaurant_staff (restaurant_id, employee_id, status)
  values ((select id from public.restaurants where name = 'A''s Bistro'), tests.get_supabase_uid('employee_2'), 'pending');

-- Setup: C's Cafe - sections only, no layout.
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_a'), 'C''s Cafe');
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'C''s Cafe'), d, 0, 1440
  from generate_series(0, 6) as d;
insert into public.sections (restaurant_id, name, capacity, color_index)
  values ((select id from public.restaurants where name = 'C''s Cafe'), 'Unutra', 4, 0);
insert into public.sections (restaurant_id, name, capacity, color_index)
  values ((select id from public.restaurants where name = 'C''s Cafe'), 'Basta', 3, 1);
insert into public.restaurant_staff (restaurant_id, employee_id, status)
  values ((select id from public.restaurants where name = 'C''s Cafe'), tests.get_supabase_uid('employee_1'), 'accepted');

-- Setup: D's Grill - neither sections nor a layout, plain capacity.
insert into public.restaurants (owner_id, name, capacity) values (tests.get_supabase_uid('owner_a'), 'D''s Grill', 4);
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'D''s Grill'), d, 0, 1440
  from generate_series(0, 6) as d;

-- === A's Bistro: explicit multi-table booking ===
select tests.authenticate_as('customer_1');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      8,
      (date_trunc('day', now()) + interval '1 day 12 hours'),
      60,
      null,
      array[
        (select id from public.tables where name = 'Sto Mali'),
        (select id from public.tables where name = 'Sto Veliki')
      ]
    )$$,
  'customer_1 can book two explicit tables covering the whole party'
);

select results_eq(
  $$select count(*)::int from public.reservation_tables rt
    join public.reservations r on r.id = rt.reservation_id
    where r.customer_id = tests.get_supabase_uid('customer_1')$$,
  ARRAY[2],
  'the explicit two-table booking created two reservation_tables rows'
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

-- reservations RLS: customer sees their own, a different customer doesn't,
-- the owner and an accepted staff member do, a pending staff member and an
-- unrelated owner don't.
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1') and party_size = 8$$,
  ARRAY[1],
  'customer_1 can see their own reservation directly on the reservations table'
);

select tests.authenticate_as('customer_2');
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1') and party_size = 8$$,
  ARRAY[0],
  'customer_2 cannot see customer_1''s reservation'
);

select tests.authenticate_as('owner_a');
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1') and party_size = 8$$,
  ARRAY[1],
  'the restaurant''s owner can see the reservation'
);

select tests.authenticate_as('employee_1');
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1') and party_size = 8$$,
  ARRAY[1],
  'an accepted staff member can see the reservation'
);

select tests.authenticate_as('employee_2');
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1') and party_size = 8$$,
  ARRAY[0],
  'a pending (not yet accepted) staff member cannot see the reservation'
);

select tests.authenticate_as('owner_b');
select results_eq(
  $$select count(*)::int from public.reservations where customer_id = tests.get_supabase_uid('customer_1') and party_size = 8$$,
  ARRAY[0],
  'an unrelated owner cannot see another restaurant''s reservation'
);

-- Double-booking either of those tables over an overlapping range fails.
select tests.authenticate_as('customer_2');
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '1 day 12 hours 30 minutes'),
      60,
      null,
      array[(select id from public.tables where name = 'Sto Mali')]
    )$$,
  'P0001',
  'Sto je već rezervisan u to vreme.',
  'double-booking an already-reserved table over an overlapping range is rejected'
);

-- No table given: auto-assigned to the single table that alone covers the
-- party (Sto Veliki, 6 seats >= 5), not both tables.
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      5,
      (date_trunc('day', now()) + interval '2 days 12 hours'),
      60
    )$$,
  'customer_2 can book with no table chosen - the system auto-assigns one'
);

select results_eq(
  $$select t.name from public.reservation_tables rt
    join public.reservations r on r.id = rt.reservation_id
    join public.tables t on t.id = rt.table_id
    where r.customer_id = tests.get_supabase_uid('customer_2') and r.party_size = 5$$,
  ARRAY['Sto Veliki'],
  'auto-assignment picked the single table that covers the party rather than splitting'
);

-- Duration limits, independent of everything else.
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '3 days 12 hours'),
      20
    )$$,
  'P0001',
  'Rezervacija mora trajati bar 30 minuta.',
  'a 20-minute stay is rejected as too short'
);

select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '3 days 12 hours'),
      200
    )$$,
  'P0001',
  'Rezervacija ne može trajati duže od 3 sata.',
  'a 200-minute stay is rejected as too long'
);

-- Explicit tables: duplicates and insufficient combined seats.
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '3 days 12 hours'),
      60,
      null,
      array[
        (select id from public.tables where name = 'Sto Mali'),
        (select id from public.tables where name = 'Sto Mali')
      ]
    )$$,
  'P0001',
  'Isti sto je izabran više puta.',
  'the same table listed twice in an explicit booking is rejected'
);

select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      10,
      (date_trunc('day', now()) + interval '3 days 12 hours'),
      60,
      null,
      array[
        (select id from public.tables where name = 'Sto Mali'),
        (select id from public.tables where name = 'Sto Veliki')
      ]
    )$$,
  'P0001',
  'Izabrani stolovi ne mogu da prime toliko gostiju.',
  'explicit tables whose combined seats fall short of the party are rejected'
);

-- reservation_tables RLS: customer can see their own row directly, an
-- unrelated owner cannot.
select tests.authenticate_as('customer_1');
select results_eq(
  $$select count(*)::int from public.reservation_tables rt
    where rt.table_id = (select id from public.tables where name = 'Sto Mali')$$,
  ARRAY[1],
  'customer_1 can see the reservation_tables row for their own booked table'
);

select tests.authenticate_as('owner_b');
select results_eq(
  $$select count(*)::int from public.reservation_tables rt
    where rt.table_id = (select id from public.tables where name = 'Sto Mali')$$,
  ARRAY[0],
  'an unrelated owner cannot see that reservation_tables row'
);

select tests.authenticate_as('employee_1');
select results_eq(
  $$select count(*)::int from public.reservation_tables rt
    where rt.table_id = (select id from public.tables where name = 'Sto Mali')$$,
  ARRAY[1],
  'an accepted staff member can see the reservation_tables row'
);

-- === C's Cafe: section auto-split ===
select tests.authenticate_as('customer_1');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'C''s Cafe'),
      5,
      (date_trunc('day', now()) + interval '1 day 12 hours'),
      60
    )$$,
  'customer_1 can book a party too big for either section alone - it auto-splits'
);

select results_eq(
  $$select count(*)::int from public.reservation_sections rs
    join public.reservations r on r.id = rs.reservation_id
    where r.customer_id = tests.get_supabase_uid('customer_1') and r.restaurant_id = (select id from public.restaurants where name = 'C''s Cafe')$$,
  ARRAY[2],
  'the auto-split booking created rows in two sections'
);

select results_eq(
  $$select sum(rs.party_size)::int from public.reservation_sections rs
    join public.reservations r on r.id = rs.reservation_id
    where r.customer_id = tests.get_supabase_uid('customer_1') and r.restaurant_id = (select id from public.restaurants where name = 'C''s Cafe')$$,
  ARRAY[5],
  'the split allocations sum back to the full party size'
);

-- Explicit section without enough remaining room is rejected outright (no
-- spillover into the other section).
select tests.authenticate_as('customer_2');
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'C''s Cafe'),
      4,
      (date_trunc('day', now()) + interval '1 day 12 hours 30 minutes'),
      60,
      (select id from public.sections where name = 'Basta')
    )$$,
  'P0001',
  'Nema dovoljno slobodnih mesta u izabrano vreme.',
  'an explicit section without enough remaining capacity is rejected, not spilled over'
);

-- reservation_sections RLS: same shape as reservation_tables above.
select tests.authenticate_as('customer_1');
select results_eq(
  $$select count(*)::int from public.reservation_sections rs
    where rs.section_id = (select id from public.sections where name = 'Unutra')$$,
  ARRAY[1],
  'customer_1 can see the reservation_sections row for their own booking'
);

select tests.authenticate_as('owner_b');
select results_eq(
  $$select count(*)::int from public.reservation_sections rs
    where rs.section_id = (select id from public.sections where name = 'Unutra')$$,
  ARRAY[0],
  'an unrelated owner cannot see that reservation_sections row'
);

select tests.authenticate_as('employee_1');
select results_eq(
  $$select count(*)::int from public.reservation_sections rs
    where rs.section_id = (select id from public.sections where name = 'Unutra')$$,
  ARRAY[1],
  'an accepted staff member can see the reservation_sections row'
);

-- === D's Grill: original plain-capacity baseline, unchanged ===
select tests.authenticate_as('customer_1');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'D''s Grill'),
      4,
      (date_trunc('day', now()) + interval '1 day 12 hours'),
      60
    )$$,
  'customer_1 can book up to the restaurant''s plain capacity'
);

select tests.authenticate_as('customer_2');
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'D''s Grill'),
      1,
      (date_trunc('day', now()) + interval '1 day 12 hours 30 minutes'),
      60
    )$$,
  'P0001',
  'Nema dovoljno slobodnih mesta u izabrano vreme.',
  'a party exceeding the restaurant''s remaining plain capacity is rejected'
);

select * from finish();
rollback;
