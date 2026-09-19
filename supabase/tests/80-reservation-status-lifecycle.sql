-- Coverage for supabase/migrations/20260917140000_reservation_status_lifecycle.sql,
-- 20260918100000_ongoing_moves_start_to_now.sql and
-- 20260918130000_reservation_lifecycle_review_fixes.sql and
-- 20260919170000_reservation_status_undo.sql:
-- update_reservation_status()'s transition graph (confirmed ->
-- [preparing_order -> order_prepared ->] ongoing -> completed, plus
-- confirmed/order_prepared -> no_show only once starts_at has passed), the
-- one-step-at-a-time undo before the guest is seated (order_prepared ->
-- preparing_order -> confirmed, status label only) and the steps back that
-- stay rejected, staff-only permission (and no anon access), an early "ongoing" moving
-- starts_at up to now() - only within 60 minutes of the booked start -,
-- early completion shrinking ends_at so the freed table slot is actually
-- bookable again through the exclusion constraint (not just a status
-- relabel), no transitions on an already-ended reservation, and the
-- reservation_tables time range staying in lockstep with the reservation's
-- own after every one of those rewrites.
--
-- I's Café (owner_e) has three tables ("Sto Z", "Sto Y", "Sto X") on an
-- active layout, 24/7 hours, and a single no-options menu item "Pica" -
-- just enough to book both a plain reservation and an order-linked one.
-- employee_2 is inserted straight into restaurant_staff as 'accepted'
-- (service_role), skipping the apply/accept dance that's already covered by
-- 20-restaurant-staff-rls.sql. employee_3 is deliberately staff nowhere, to
-- exercise the permission check.
--
-- Times are relative to now() (20-55 minutes out) rather than "tomorrow at
-- 12:00": marking a reservation ongoing early is only allowed within 60
-- minutes of its starts_at, so a fixed clock time would pass or fail
-- depending on what time of day the suite happens to run. Inside one
-- pgTAP transaction now() is constant, which is also why completing right
-- after starting relies on the function's "ends_at is at least starts_at +
-- 1 second" clamp. "Already started"/"already ended" reservations are
-- simulated with a direct service_role backdate, same as
-- 70-capacity-guards.sql simulates "no longer active" - create_reservation()
-- itself refuses a past starts_at, and there is no time-travel helper wired
-- into these security definer functions (search_path = '' bypasses
-- tests.freeze_time()).
begin;
select plan(42);

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
insert into public.tables (restaurant_id, layout_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'I''s Café'),
    (select id from public.layouts where name = 'Raspored'),
    'Sto X', 6, 8, 0, 2, 2
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
      (now() + interval '20 minutes'),
      30,
      null,
      array[(select id from public.tables where name = 'Sto Z')]
    )$$,
  'customer_4 books Sto Z for R1, 20 minutes from now, no order'
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
  'starting R1 early moved its starts_at up from 20 minutes out to now()'
);

select ok(
  (select bool_and(rt.starts_at = r.starts_at and rt.ends_at = r.ends_at)
   from public.reservation_tables rt join public.reservations r on r.id = rt.reservation_id
   where r.customer_id = tests.get_supabase_uid('customer_4') and r.party_size = 2),
  'after the early start, R1''s reservation_tables range matches the reservation''s own starts_at/ends_at'
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
  'completing R1 early shrank its ends_at from the original 50-minutes-out booked end to right around now()'
);

select ok(
  (select bool_and(rt.starts_at = r.starts_at and rt.ends_at = r.ends_at)
   from public.reservation_tables rt join public.reservations r on r.id = rt.reservation_id
   where r.customer_id = tests.get_supabase_uid('customer_4') and r.party_size = 2),
  'after the early completion, R1''s reservation_tables range still matches the reservation''s own starts_at/ends_at'
);

select tests.authenticate_as('customer_4');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'I''s Café'),
      2,
      (now() + interval '20 minutes'),
      30,
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
      (now() + interval '20 minutes'),
      30,
      null,
      array[(select id from public.tables where name = 'Sto Y')],
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_4') and status = 'draft')
    )$$,
  'customer_4 books R3 (party of 3, distinct from R1/R2''s party of 2) on Sto Y, 20 minutes from now, with the cart attached'
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
  'R3 cannot be marked no_show before its starts_at (20 minutes out) has arrived'
);

select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'confirmed'),
      'preparing_order'
    )$$,
  'R3 confirmed -> preparing_order (it has a confirmed order)'
);

select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'preparing_order'),
      'confirmed'
    )$$,
  'R3 preparing_order -> confirmed (undo of a misclicked "start preparing")'
);

select results_eq(
  $$select status from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3$$,
  $$values ('confirmed'::text)$$,
  'R3 is back to confirmed'
);

select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'confirmed'),
      'confirmed'
    )$$,
  'P0001',
  'Rezervacija može biti vraćena na "Potvrđena" samo dok se porudžbina priprema.',
  'a reservation that is already confirmed has nothing to step back from'
);

select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'confirmed'),
      'preparing_order'
    )$$,
  'R3 confirmed -> preparing_order again after the undo'
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
      'preparing_order'
    )$$,
  'R3 order_prepared -> preparing_order (undo of a misclicked "order is ready")'
);

select lives_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'preparing_order'),
      'order_prepared'
    )$$,
  'R3 preparing_order -> order_prepared once more'
);

select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3 and status = 'order_prepared'),
      'confirmed'
    )$$,
  'P0001',
  'Rezervacija može biti vraćena na "Potvrđena" samo dok se porudžbina priprema.',
  'order_prepared cannot jump straight back to confirmed - the undo goes one step at a time'
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

select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 3),
      'preparing_order'
    )$$,
  'P0001',
  'Priprema porudžbine je moguća samo iz statusa "Potvrđena" ili "Porudžbina spremna" rezervacije koja ima porudžbinu.',
  'a completed reservation cannot be stepped back - only the pre-seating stages can be undone'
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
  'Rezervacija može biti označena kao u toku najviše 60 minuta pre zakazanog početka.',
  'R4 cannot be started early: it is booked days out, far beyond the 60-minute early-start window'
);

-- === R5/R6 on Sto X: starting R6 early would collide with R5 on the same
-- === table (nothing else is on Sto X, so R5 is the only possible cause) ===
select tests.authenticate_as('customer_4');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'I''s Café'),
      5,
      (now() + interval '20 minutes'),
      30,
      null,
      array[(select id from public.tables where name = 'Sto X')]
    )$$,
  'customer_4 books R5 (party of 5, Sto X has 6 seats) on Sto X, 20 minutes from now'
);

select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'I''s Café'),
      1,
      (now() + interval '55 minutes'),
      30,
      null,
      array[(select id from public.tables where name = 'Sto X')]
    )$$,
  'customer_4 books R6 (party of 1) on Sto X, 55 minutes out - after R5''s slot, so no conflict yet, and inside the 60-minute early-start window'
);

select tests.authenticate_as('employee_2');
select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 1),
      'ongoing'
    )$$,
  'P0001',
  'Sto je zauzet pre početka ove rezervacije - ne može biti označena kao u toku.',
  'R6 cannot be started early: pulling its starts_at up to now() would overlap R5 on Sto X'
);

select tests.authenticate_as_service_role();
update public.reservations
  set starts_at = now() - interval '2 hours', ends_at = now() - interval '1 hour'
  where restaurant_id = (select id from public.restaurants where name = 'I''s Café')
    and party_size = 1;

select tests.authenticate_as('employee_2');
select throws_ok(
  $$select public.update_reservation_status(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 1),
      'ongoing'
    )$$,
  'P0001',
  'Rezervacija je već istekla.',
  'a reservation whose ends_at has already passed accepts no transitions, even before the cron sweep has caught up with it'
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

select ok(
  (select bool_and(rt.starts_at = r.starts_at and rt.ends_at = r.ends_at)
   from public.reservation_tables rt join public.reservations r on r.id = rt.reservation_id
   where r.restaurant_id = (select id from public.restaurants where name = 'I''s Café') and r.party_size = 4),
  'after the no_show, R4''s reservation_tables range was brought in line with the reservation''s own (backdated) starts_at and shrunk ends_at'
);

-- The id is resolved as service_role and stashed in a transaction-local
-- setting: employee_3 can't see this restaurant's reservations at all
-- (staff-only RLS), so a subselect run as them would come back null and
-- the call would fail with "doesn't exist" instead of reaching the
-- permission check this test is about.
select tests.authenticate_as_service_role();
select set_config('tests.r4_id',
  (select id::text from public.reservations
   where restaurant_id = (select id from public.restaurants where name = 'I''s Café') and party_size = 4),
  true);

select tests.authenticate_as('employee_3');
select throws_ok(
  $$select public.update_reservation_status(current_setting('tests.r4_id')::uuid, 'ongoing')$$,
  'P0001',
  'Nemate dozvolu da menjate status ove rezervacije.',
  'employee_3, staff nowhere, has no permission over I''s Café''s reservations'
);

select tests.clear_authentication();
select throws_ok(
  $$select public.update_reservation_status(gen_random_uuid(), 'ongoing')$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot execute update_reservation_status at all'
);

select * from finish();
rollback;
