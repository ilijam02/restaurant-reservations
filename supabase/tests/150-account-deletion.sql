-- Coverage for supabase/migrations/20260919200000_account_deletion.sql:
-- delete_my_account() and account_deletion_plan() for all three roles, and the
-- three foreign keys that now detach (set null) instead of cascading.
--
-- customer_9 is the customer who deletes their account. Their bookings are at
-- Nalog Drugi (owner_k): R1 (party 2, with an order, later cancelled), R2
-- (party 3, made ongoing and then completed) and R3 (party 4, confirmed but
-- backdated so it has already ended - the cron sweep just hasn't recorded it
-- yet), plus a draft cart. customer_10 is a bystander with one booking at
-- Nalog Drugi (party 5) and one at Nalog Istorija (party 6) that must survive
-- everything. owner_j owns Nalog Istorija (has reservation history, so it is
-- archived) and Nalog Prazno (no reservations, so it is really deleted).
-- employee_6 has an accepted application at Nalog Istorija and a pending one
-- at Nalog Prazno. Order matters: the employee and the customer go before the
-- owner, since deleting the owner archives Nalog Istorija and removes its staff.
begin;
select plan(41);

select tests.create_supabase_user('owner_j', 'ownerj@test.com', null,
  '{"first_name":"Owner","last_name":"J","phone":"555-0041","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_k', 'ownerk@test.com', null,
  '{"first_name":"Owner","last_name":"K","phone":"555-0042","role":"owner"}'::jsonb);
select tests.create_supabase_user('employee_6', 'employee6@test.com', null,
  '{"first_name":"Emp","last_name":"Six","phone":"555-0043","role":"employee"}'::jsonb);
select tests.create_supabase_user('customer_9', 'customer9@test.com', null,
  '{"first_name":"Cust","last_name":"Nine","phone":"555-0044","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_10', 'customer10@test.com', null,
  '{"first_name":"Cust","last_name":"Ten","phone":"555-0045","role":"customer"}'::jsonb);

-- === Setup ===
select tests.authenticate_as('owner_k');
insert into public.restaurants (owner_id, name, capacity)
  values (tests.get_supabase_uid('owner_k'), 'Nalog Drugi', 30);
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select r.id, d, 0, 1440
  from public.restaurants r, generate_series(0, 6) as d
  where r.name = 'Nalog Drugi';
insert into public.menu_items (restaurant_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'Nalog Drugi'), 'Pica D', 500, true);

select tests.authenticate_as('owner_j');
insert into public.restaurants (owner_id, name, capacity)
  values (tests.get_supabase_uid('owner_j'), 'Nalog Istorija', 30);
insert into public.restaurants (owner_id, name)
  values (tests.get_supabase_uid('owner_j'), 'Nalog Prazno');
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select r.id, d, 0, 1440
  from public.restaurants r, generate_series(0, 6) as d
  where r.name in ('Nalog Istorija', 'Nalog Prazno');

select tests.authenticate_as('employee_6');
insert into public.restaurant_staff (restaurant_id, employee_id)
  select id, tests.get_supabase_uid('employee_6')
  from public.restaurants where name in ('Nalog Istorija', 'Nalog Prazno');

select tests.authenticate_as_service_role();
update public.restaurant_staff set status = 'accepted'
  where restaurant_id = (select id from public.restaurants where name = 'Nalog Istorija');
select set_config('tests.drugi_id', (select id::text from public.restaurants where name = 'Nalog Drugi'), true);
select set_config('tests.istorija_id', (select id::text from public.restaurants where name = 'Nalog Istorija'), true);
select set_config('tests.prazno_id', (select id::text from public.restaurants where name = 'Nalog Prazno'), true);
select set_config('tests.c9', tests.get_supabase_uid('customer_9')::text, true);
select set_config('tests.c10', tests.get_supabase_uid('customer_10')::text, true);
select set_config('tests.oj', tests.get_supabase_uid('owner_j')::text, true);
select set_config('tests.ok', tests.get_supabase_uid('owner_k')::text, true);
select set_config('tests.e6', tests.get_supabase_uid('employee_6')::text, true);

-- customer_9 books R1 together with an order; the bystander books elsewhere.
select tests.authenticate_as('customer_9');
select public.start_cart(current_setting('tests.drugi_id')::uuid);
select public.add_order_item(
  (select id from public.orders where customer_id = current_setting('tests.c9')::uuid and status = 'draft'),
  (select id from public.menu_items where name = 'Pica D')
);
select lives_ok(
  $$select public.create_reservation(
      current_setting('tests.drugi_id')::uuid, 2, (now() + interval '2 hours'), 60,
      null, null,
      (select id from public.orders where customer_id = current_setting('tests.c9')::uuid and status = 'draft')
    )$$,
  'customer_9 books R1 (party of 2) at Nalog Drugi together with an order'
);

select tests.authenticate_as('customer_10');
select lives_ok(
  $$select public.create_reservation(current_setting('tests.drugi_id')::uuid, 5, (now() + interval '3 hours'), 60)$$,
  'customer_10 books a party of 5 at Nalog Drugi'
);
select lives_ok(
  $$select public.create_reservation(current_setting('tests.istorija_id')::uuid, 6, (now() + interval '3 hours'), 60)$$,
  'customer_10 books a party of 6 at Nalog Istorija'
);

-- === Permissions ===
select tests.clear_authentication();
select throws_ok(
  $$select public.delete_my_account()$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot execute delete_my_account'
);
select throws_ok(
  $$select * from public.account_deletion_plan()$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot execute account_deletion_plan'
);

-- === Customer: refused while a booking is active ===
select tests.authenticate_as('customer_9');
select results_eq(
  $$select role, active_reservations, history_reservations, blocking_restaurants, restaurants_to_delete, restaurants_to_archive
    from public.account_deletion_plan()$$,
  $$values ('customer'::text, 1, 1, '[]'::jsonb, '{}'::uuid[], 0)$$,
  'customer_9''s plan shows one active booking and one booking of history, and owns nothing'
);

select throws_ok(
  $$select public.delete_my_account()$$,
  'P0001',
  'Imate aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.',
  'a customer with a confirmed booking cannot delete their account'
);

select lives_ok(
  $$select public.cancel_reservation(
      (select id from public.reservations where customer_id = current_setting('tests.c9')::uuid and party_size = 2)
    )$$,
  'customer_9 cancels R1'
);

select lives_ok(
  $$select public.create_reservation(current_setting('tests.drugi_id')::uuid, 3, (now() + interval '5 hours'), 60)$$,
  'customer_9 books R2 (party of 3)'
);
select lives_ok(
  $$select public.create_reservation(current_setting('tests.drugi_id')::uuid, 4, (now() + interval '8 hours'), 60)$$,
  'customer_9 books R3 (party of 4)'
);

-- An ongoing booking can't be cancelled by the customer, so it blocks until completed.
select tests.authenticate_as_service_role();
update public.reservations set status = 'ongoing'
  where customer_id = current_setting('tests.c9')::uuid and party_size = 3;

select tests.authenticate_as('customer_9');
select throws_ok(
  $$select public.delete_my_account()$$,
  'P0001',
  'Imate aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.',
  'an ongoing booking blocks account deletion'
);

-- R2 completes; R3 has ended but the sweep hasn't recorded that yet.
select tests.authenticate_as_service_role();
update public.reservations set status = 'completed'
  where customer_id = current_setting('tests.c9')::uuid and party_size = 3;
update public.reservations set starts_at = now() - interval '2 hours', ends_at = now() - interval '1 hour'
  where customer_id = current_setting('tests.c9')::uuid and party_size = 4;

-- A fresh draft cart, which must go with the account.
select tests.authenticate_as('customer_9');
select public.start_cart(current_setting('tests.drugi_id')::uuid);
select public.add_order_item(
  (select id from public.orders where customer_id = current_setting('tests.c9')::uuid and status = 'draft'),
  (select id from public.menu_items where name = 'Pica D')
);

select results_eq(
  $$select active_reservations, history_reservations from public.account_deletion_plan()$$,
  $$values (0, 3)$$,
  'with R1 cancelled, R2 completed and R3 already ended, nothing is active any more (three bookings stay as history)'
);

-- === Customer: deleted, and anonymized rather than erased ===
select lives_ok(
  $$select public.delete_my_account()$$,
  'customer_9 deletes their account once nothing is active'
);

reset role;
select is(
  (select count(*) from auth.users where id = current_setting('tests.c9')::uuid),
  0::bigint,
  'the auth user is gone'
);
select is(
  (select count(*) from public.profiles where id = current_setting('tests.c9')::uuid),
  0::bigint,
  'the profile (name, phone) is gone'
);
select is(
  (select count(*) from public.reservations
   where restaurant_id = current_setting('tests.drugi_id')::uuid and customer_id is null),
  3::bigint,
  'customer_9''s three bookings stay, with no customer attached'
);
select is(
  (select count(*) from public.reservations
   where restaurant_id = current_setting('tests.drugi_id')::uuid and customer_id = current_setting('tests.c10')::uuid),
  1::bigint,
  'the bystander''s booking at the same restaurant is untouched'
);
select is(
  (select count(*) from public.reservations
   where restaurant_id = current_setting('tests.drugi_id')::uuid and status = 'cancelled' and cancelled_by is null),
  1::bigint,
  'the cancelled booking keeps its cancelled status, but nobody is recorded as having cancelled it any more'
);
select is(
  (select count(*) from public.orders
   where restaurant_id = current_setting('tests.drugi_id')::uuid and status = 'cancelled' and customer_id is null),
  1::bigint,
  'the order that came with R1 is kept (cancelled), anonymized'
);
select is(
  (select count(*) from public.orders
   where restaurant_id = current_setting('tests.drugi_id')::uuid and status = 'draft'),
  0::bigint,
  'the draft cart is deleted'
);
select is(
  (select count(*) from public.order_items where item_name = 'Pica D'),
  1::bigint,
  'the kept order still has its item; only the draft cart''s item is gone'
);

select tests.authenticate_as('owner_k');
select is(
  (select count(*) from public.reservations where restaurant_id = current_setting('tests.drugi_id')::uuid),
  4::bigint,
  'the restaurant''s owner still sees all four bookings, three of them anonymized'
);

-- The user row is gone, so tests.authenticate_as() can no longer look it up:
-- the old session's claims are set by hand.
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', json_build_object('sub', current_setting('tests.c9'))::text, true);
select throws_ok(
  $$select public.delete_my_account()$$,
  'P0001',
  'Nalog ne postoji.',
  'a second call with the old session finds no account'
);
select is_empty(
  $$select * from public.account_deletion_plan()$$,
  'and the plan is empty'
);

-- === Employee ===
select tests.authenticate_as('employee_6');
select results_eq(
  $$select role, active_reservations, history_reservations, blocking_restaurants, restaurants_to_delete, restaurants_to_archive
    from public.account_deletion_plan()$$,
  $$values ('employee'::text, 0, 0, '[]'::jsonb, '{}'::uuid[], 0)$$,
  'an employee''s plan is empty apart from their role'
);
select lives_ok(
  $$select public.delete_my_account()$$,
  'an employee (accepted at one restaurant, pending at another) can delete their account'
);

reset role;
select is(
  (select count(*) from auth.users where id = current_setting('tests.e6')::uuid),
  0::bigint,
  'the employee''s auth user is gone'
);
select is(
  (select count(*) from public.restaurant_staff where employee_id = current_setting('tests.e6')::uuid),
  0::bigint,
  'their applications and staff rows went with it'
);
select is(
  (select count(*) from public.restaurants
   where id in (current_setting('tests.istorija_id')::uuid, current_setting('tests.prazno_id')::uuid)),
  2::bigint,
  'the restaurants they worked at are untouched'
);

-- === Owner: refused while a restaurant has an active reservation ===
select tests.authenticate_as('owner_j');
select results_eq(
  $$select role, active_reservations, history_reservations, blocking_restaurants, restaurants_to_delete, restaurants_to_archive
    from public.account_deletion_plan()$$,
  $$values (
    'owner'::text, 0, 0,
    jsonb_build_array(jsonb_build_object(
      'id', current_setting('tests.istorija_id')::uuid, 'name', 'Nalog Istorija', 'active_reservations', 1)),
    array[current_setting('tests.prazno_id')::uuid],
    1
  )$$,
  'the owner''s plan names the restaurant with an active booking, the one to delete and the count to archive'
);

select throws_ok(
  $$select public.delete_my_account()$$,
  'P0001',
  'Restoran „Nalog Istorija” ima aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.',
  'an owner cannot delete their account while a restaurant has an active booking'
);

reset role;
select is(
  (select count(*) from auth.users where id = current_setting('tests.oj')::uuid)
    + (select count(*) from public.restaurants where owner_id = current_setting('tests.oj')::uuid),
  3::bigint,
  'the refused call changed nothing: the owner and both restaurants are still there'
);

update public.reservations set status = 'completed'
  where restaurant_id = current_setting('tests.istorija_id')::uuid;

-- === Owner: deleted; restaurants deleted or archived and detached ===
select tests.authenticate_as('owner_j');
select results_eq(
  $$select active_reservations, blocking_restaurants, restaurants_to_delete, restaurants_to_archive
    from public.account_deletion_plan()$$,
  $$values (0, '[]'::jsonb, array[current_setting('tests.prazno_id')::uuid], 1)$$,
  'once the booking is completed nothing blocks any more'
);
select lives_ok(
  $$select public.delete_my_account()$$,
  'the owner deletes their account'
);

reset role;
select is(
  (select count(*) from auth.users where id = current_setting('tests.oj')::uuid),
  0::bigint,
  'the owner''s auth user is gone'
);
select is(
  (select count(*) from public.restaurants where id = current_setting('tests.prazno_id')::uuid),
  0::bigint,
  'the restaurant with no history is really deleted'
);
select ok(
  (select archived_at is not null and owner_id is null
   from public.restaurants where id = current_setting('tests.istorija_id')::uuid),
  'the restaurant with history is archived and detached from its owner'
);
select is(
  (select count(*) from public.reservations
   where restaurant_id = current_setting('tests.istorija_id')::uuid and customer_id = current_setting('tests.c10')::uuid),
  1::bigint,
  'the customer''s booking at the archived restaurant is intact'
);
select ok(
  (select owner_id = current_setting('tests.ok')::uuid
   from public.restaurants where id = current_setting('tests.drugi_id')::uuid),
  'another owner''s restaurant is untouched'
);

select tests.authenticate_as('customer_10');
select is(
  (select count(*) from public.restaurants where id = current_setting('tests.istorija_id')::uuid),
  1::bigint,
  'customer_10 can still read the detached archived restaurant, so their history still shows its name'
);
select results_eq(
  $$select role, active_reservations, history_reservations from public.account_deletion_plan()$$,
  $$values ('customer'::text, 1, 2)$$,
  'a plan only ever counts the caller''s own bookings'
);

select * from finish();
