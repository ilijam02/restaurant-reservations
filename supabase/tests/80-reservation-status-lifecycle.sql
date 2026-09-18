-- Coverage for supabase/migrations/20260917140000_reservation_status_lifecycle.sql
-- and 20260918100000_ongoing_moves_start_to_now.sql:
-- update_reservation_status()'s transition graph (confirmed ->
-- [preparing_order -> order_prepared ->] ongoing -> completed, plus
-- confirmed/order_prepared -> no_show only once starts_at has passed),
-- staff-only permission, an early "ongoing" moving starts_at up to now(),
-- and early completion shrinking ends_at so the freed table slot is
-- actually bookable again through the exclusion constraint (not just a
-- status relabel - see the migrations' own comments on why both matter).
--
-- I's Café (owner_e) has two tables ("Sto Z", "Sto Y") on an active layout,
-- 24/7 hours, and a single no-options menu item "Pica" - just enough to
-- book both a plain reservation and an order-linked one. employee_2 is
-- inserted straight into restaurant_staff as 'accepted' (service_role),
-- skipping the apply/accept dance that's already covered by
-- 20-restaurant-staff-rls.sql. employee_3 is deliberately staff nowhere, to
-- exercise the permission check.
--
-- Times are relative to now() (a few hours out) rather than "tomorrow at
-- 12:00": moving starts_at up to now() is only allowed while the
-- reservation ends within 24 hours, so a fixed clock time would pass or
-- fail depending on what time of day the suite happens to run. Inside one
-- pgTAP transaction now() is constant, which is also why completing right
-- after starting relies on the function's "ends_at is at least starts_at +
-- 1 second" clamp. "Already started" reservations are simulated with a
-- direct service_role backdate, same as 70-capacity-guards.sql simulates
-- "no longer active" - create_reservation() itself refuses a past
-- starts_at, and there is no time-travel helper wired into these security
-- definer functions (search_path = '' bypasses tests.freeze_time()).
begin;
select plan(28);

select tests.create_supabase_user('owner_e', 'ownere@test.com', null,
  '{"first_name":"Owner","last_name":"E","phone":"555-0009","role":"owner"}'::jsonb);
select tests.create_supabase_user('employee_2', 'employee2@test.com', null,
  '{"first_name":"Emp","last_name":"Two","phone":"555-0010","role":"employee"}'::jsonb);
select tests.create_supabase_user('employee_3', 'employee3@test.com', null,
  '{"first_name":"Emp","last_name":"Three","phone":"555-0011","role":"employee"}'::jsonb);
select tests.create_supabase_user('customer_4', 'customer4@test.com', null,
  '{"first_name":"Cust","last_name":"Four","phone":"555-0012","role":"customer"}'::jsonb);

select tests.authenticate_as('owner_e');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_e'), 'I''s Café');
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'I''s Café'), d, 0, 1440
  from generate_series(0, 6) as d;
insert into public.layouts (restaurant_id, name, is_active)
  values ((select id from public.restaurants where name = 'I''s Café'), 'Raspored', true);
insert into public.tables (restaurant_id, layout_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'I''s Café'),
    (select id from public.layouts where name = 'Raspored'),
    'Sto Z', 4, 0, 0, 2, 2
  );
insert into public.tables (restaurant_id, layout_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'I''s Café'),
    (select id from public.layouts where name = 'Raspored'),
    'Sto Y', 4, 4, 0, 2, 2
  );
insert into public.menu_items (restaurant_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'I''s Café'), 'Pica', 500, true);

select tests.authenticate_as_service_role();
insert into public.restaurant_staff (restaurant_id, employee_id, status)
  values (
    (select id from public.restaurants where name = 'I''s Café'),
    tests.get_supabase_uid('employee_2'),
    'accepted'
  );

-- === R1: no order - confirmed -> ongoing (early: starts_at moves to now())
-- === -> completed (early), and the freed exclusion-constraint slot ===
select tests.authenticate_as('customer_4');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'I''s Café'),
      2,
      (now() + interval '2 hours'),
      60,
      null,
      array[(select id from public.tables where name = 'Sto Z')]
    )$$,
  'customer_4 books Sto Z for R1, 2 hours from now, no order'
);

select tests.authenticate_as('employee_2');
select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where customer_id = tests.get_supabase_uid('customer_4') and party_size = 2),
      'ongoing'
    )$$,
  'employee_2 (accepted staff, no order on the reservation) moves R1 confirmed -> ongoing directly, before its starts_at'
);

select results_eq(
  $$select status from public.reservations where customer_id = tests.get_supabase_uid('customer_4') and party_size = 2$$,
  $$values ('ongoing'::text)$$,
  'R1 is now ongoing'
);

select ok(
  (select starts_at <= now() and starts_at > now() - interval '1 minute'
   from public.reservations where customer_id = tests.get_supabase_uid('customer_4') and party_size = 2),
  'starting R1 early moved its starts_at up from 2 hours out to now()'
);

select tests.authenticate_as('customer_4');
select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where customer_id = tests.get_supabase_uid('customer_4') and party_size = 2),
      'completed'
    )$$,
  'P0001',
  'Nemate dozvolu da menjate status ove rezervacije.',
  'the customer who booked R1 has no permission to change its status - only accepted staff can'
);

select tests.authenticate_as('employee_2');
select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where customer_id = tests.get_supabase_uid('customer_4') and party_size = 2),
      'completed'
    )$$,
  'employee_2 completes R1 well before its originally booked ends_at (early completion)'
);

select results_eq(
  $$select status from public.reservations where customer_id = tests.get_supabase_uid('customer_4') and party_size = 2$$,
  $$values ('completed'::text)$$,
  'R1 is now completed'
);

select ok(
  (select ends_at < now() + interval '1 minute'
   from public.reservations where customer_id = tests.get_supabase_uid('customer_4') and party_size = 2),
  'completing R1 early shrank its ends_at from the original 3-hours-out booked end to right around now()'
);

select tests.authenticate_as('customer_4');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'I''s Café'),
      2,
      (now() + interval '2 hours'),
      60,
      null,
      array[(select id from public.tables where name = 'Sto Z')]
    )$$,
  'R2 books the exact same table and time slot R1 originally held - only possible because R1 moved/shrank its reservation_tables row too, freeing the exclusion constraint (a plain status change alone would not have)'
);

-- === R3: order-linked - full confirmed -> preparing_order -> order_prepared
-- === -> ongoing -> completed chain, plus the transitions that must be
-- === rejected along the way (on Sto Y so it doesn't collide with R1/R2) ===
select lives_ok(
  $$select public.start_cart((select id from public.restaurants where name = 'I''s Café'))$$,
  'customer_4 starts a cart at I''s Café'
);

select lives_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_4') and status = 'draft'),
      (select id from public.menu_items where name = 'Pica')
    )$$,
  'customer_4 adds Pica to the cart'
);

select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'I''s Café'),
      3,
      (now() + interval '2 hours'),
      60,
      null,
      array[(select id from public.tables where name = 'Sto Y')],
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_4') and status = 'draft')
    )$$,
  'customer_4 books R3 (party of 3, distinct from R1/R2''s party of 2) on Sto Y, 2 hours from now, with the cart attached'
);

select tests.authenticate_as('employee_2');
select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'confirmed'),
      'ongoing'
    )$$,
  'P0001',
  'Rezervacija ima porudžbinu - prvo je potrebno pripremiti je.',
  'R3 cannot skip straight to ongoing while it still has an order to prepare'
);

select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'confirmed'),
      'no_show'
    )$$,
  'P0001',
  'Gost može biti označen kao odsutan tek nakon početka rezervacije.',
  'R3 cannot be marked no_show before its starts_at (2 hours out) has arrived'
);

select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'confirmed'),
      'preparing_order'
    )$$,
  'R3 confirmed -> preparing_order (it has a confirmed order)'
);

select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'preparing_order'),
      'no_show'
    )$$,
  'P0001',
  'Gost može biti označen kao odsutan samo dok se čeka na dolazak.',
  'preparing_order -> no_show is not part of the transition graph (only confirmed/order_prepared can)'
);

select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'preparing_order'),
      'order_prepared'
    )$$,
  'R3 preparing_order -> order_prepared'
);

select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'order_prepared'),
      'ongoing'
    )$$,
  'R3 order_prepared -> ongoing'
);

select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'ongoing'),
      'completed'
    )$$,
  'R3 ongoing -> completed'
);

select results_eq(
  $$select status from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3$$,
  $$values ('completed'::text)$$,
  'R3 ended up completed'
);

-- === R4: booked 3 days out - too far ahead to start early; later
-- === backdated to exercise the no_show path itself ===
select tests.authenticate_as('customer_4');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'I''s Café'),
      4,
      (date_trunc('day', now()) + interval '3 days 12 hours'),
      60,
      null,
      array[(select id from public.tables where name = 'Sto Z')]
    )$$,
  'customer_4 books R4 (party of 4, distinct from every other party size in this file), 3 days out'
);

select tests.authenticate_as('employee_2');
select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 4 and status = 'confirmed'),
      'ongoing'
    )$$,
  'P0001',
  'Rezervacija počinje za više od 24 sata i ne može biti označena kao u toku.',
  'R4 cannot be started early: pulling its starts_at up to now() would stretch it past the 24-hour cap on a reservation''s length'
);

-- === R6: starting early would collide with R2 on the same table ===
select tests.authenticate_as('customer_4');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'I''s Café'),
      1,
      (now() + interval '5 hours'),
      60,
      null,
      array[(select id from public.tables where name = 'Sto Z')]
    )$$,
  'customer_4 books R6 (party of 1) on Sto Z, 5 hours out - after R2''s slot, so no conflict yet'
);

select tests.authenticate_as('employee_2');
select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 1),
      'ongoing'
    )$$,
  'P0001',
  'Sto je zauzet pre početka ove rezervacije - ne može biti označena kao u toku.',
  'R6 cannot be started early: pulling its starts_at up to now() would overlap R2 on the same table'
);

select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where customer_id = tests.get_supabase_uid('customer_4') and party_size = 2 and status = 'completed' limit 1),
      'bogus_status'
    )$$,
  'P0001',
  'Nepoznat ili nepodržan status: bogus_status.',
  'an unrecognized target status is rejected regardless of the reservation''s current state'
);

select tests.authenticate_as_service_role();
update public.reservations
  set starts_at = now() - interval '10 minutes', ends_at = now() + interval '20 minutes'
  where restaurant_id = (select id from public.restaurants where name = 'I''s Café')
    and party_size = 4
    and status = 'confirmed';

select tests.authenticate_as('employee_2');
select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 4 and status = 'confirmed'),
      'no_show'
    )$$,
  'R4 confirmed -> no_show now that its (backdated) starts_at has passed'
);

select results_eq(
  $$select status from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 4$$,
  $$values ('no_show'::text)$$,
  'R4 is now no_show'
);

select tests.authenticate_as('employee_3');
select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 4 and status = 'no_show'),
      'ongoing'
    )$$,
  'P0001',
  'Nemate dozvolu da menjate status ove rezervacije.',
  'employee_3, staff nowhere, has no permission over I''s Café''s reservations'
);

select * from finish();
rollback;
