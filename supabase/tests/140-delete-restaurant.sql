-- Coverage for supabase/migrations/20260919180000_delete_restaurant.sql and its review follow-up 20260919190000_delete_restaurant_review_fixes.sql:
-- delete_restaurant() (owner only; refused while any reservation is active;
-- really deletes a restaurant with no reservation history, archives one that
-- has any), cancel_all_active_reservations() (owner only; skips reservations
-- that can't be cancelled, i.e. ongoing ones), restaurant_deletion_plan(), the
-- closed-off direct delete/archived_at update, and archived restaurants
-- refusing new reservations, carts and staff applications.
--
-- Brisanje Prazno (owner_h) has no reservations: a pending applicant
-- (employee_5), a menu item and customer_7's draft cart hang off it, all of
-- which the hard delete has to take with it. Brisanje Istorija (owner_h) is a
-- plain-capacity restaurant with reservations by customer_7 (a third, already-ended one is added later), told apart by
-- party_size (2 = confirmed, cancelled by cancel-all; 3 = set to ongoing, which
-- cancel-all must skip and which blocks deletion until it is completed), plus
-- accepted staff (employee_5) and a draft cart (customer_8). owner_i is "an
-- owner who owns neither".
begin;
select plan(45);

select tests.create_supabase_user('owner_h', 'ownerh@test.com', null,
  '{"first_name":"Owner","last_name":"H","phone":"555-0031","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_i', 'owneri@test.com', null,
  '{"first_name":"Owner","last_name":"I","phone":"555-0032","role":"owner"}'::jsonb);
select tests.create_supabase_user('employee_5', 'employee5@test.com', null,
  '{"first_name":"Emp","last_name":"Five","phone":"555-0033","role":"employee"}'::jsonb);
select tests.create_supabase_user('customer_7', 'customer7@test.com', null,
  '{"first_name":"Cust","last_name":"Seven","phone":"555-0034","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_8', 'customer8@test.com', null,
  '{"first_name":"Cust","last_name":"Eight","phone":"555-0035","role":"customer"}'::jsonb);

-- === Setup ===
select tests.authenticate_as('owner_h');
insert into public.restaurants (owner_id, name)
  values (tests.get_supabase_uid('owner_h'), 'Brisanje Prazno');
insert into public.restaurants (owner_id, name, capacity)
  values (tests.get_supabase_uid('owner_h'), 'Brisanje Istorija', 20);
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select r.id, d, 0, 1440
  from public.restaurants r, generate_series(0, 6) as d
  where r.name in ('Brisanje Prazno', 'Brisanje Istorija');
insert into public.menu_items (restaurant_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'Brisanje Prazno'), 'Pica P', 500, true);
-- A layout with a section and a table, so the hard delete also has to get
-- through the tables/sections delete-guard triggers while cascading.
insert into public.layouts (restaurant_id, name, is_active)
  values ((select id from public.restaurants where name = 'Brisanje Prazno'), 'Raspored P', true);
insert into public.sections (restaurant_id, name, capacity, color_index)
  values ((select id from public.restaurants where name = 'Brisanje Prazno'), 'Sala P', 4, 0);
insert into public.tables (restaurant_id, layout_id, section_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'Brisanje Prazno'),
    (select id from public.layouts where name = 'Raspored P'),
    (select id from public.sections where name = 'Sala P'),
    'Sto P1', 4, 0, 0, 2, 2
  );

select tests.authenticate_as('employee_5');
insert into public.restaurant_staff (restaurant_id, employee_id)
  select id, tests.get_supabase_uid('employee_5')
  from public.restaurants where name in ('Brisanje Prazno', 'Brisanje Istorija');

-- customer_7's draft cart at Brisanje Prazno holds an item, so the hard delete
-- also cascades through order_items while the menu item it points at is being
-- removed (menu_item_id is "on delete set null").
select tests.authenticate_as('customer_7');
select public.start_cart((select id from public.restaurants where name = 'Brisanje Prazno'));
select public.add_order_item(
  (select id from public.orders where customer_id = tests.get_supabase_uid('customer_7') and status = 'draft'),
  (select id from public.menu_items where name = 'Pica P')
);

select tests.authenticate_as('customer_8');
select lives_ok(
  $$select public.start_cart((select id from public.restaurants where name = 'Brisanje Istorija'))$$,
  'customer_8 starts a cart at Brisanje Istorija (it must not survive the archive)'
);

select tests.authenticate_as_service_role();
update public.restaurant_staff set status = 'accepted'
  where restaurant_id = (select id from public.restaurants where name = 'Brisanje Istorija');
select set_config('tests.prazno_id', (select id::text from public.restaurants where name = 'Brisanje Prazno'), true);
select set_config('tests.istorija_id', (select id::text from public.restaurants where name = 'Brisanje Istorija'), true);

-- === restaurant_deletion_plan() ===
select tests.authenticate_as('owner_h');
select results_eq(
  $$select active_reservations, cancellable_reservations, total_reservations, staff_count, menu_item_count, table_count
    from public.restaurant_deletion_plan(current_setting('tests.prazno_id')::uuid)$$,
  $$values (0, 0, 0, 1, 1, 1)$$,
  'the plan for the empty restaurant counts its pending applicant, menu item and table, and no reservations'
);

select tests.authenticate_as('owner_i');
select is_empty(
  $$select * from public.restaurant_deletion_plan(current_setting('tests.prazno_id')::uuid)$$,
  'owner_i gets no plan for a restaurant they do not own'
);

select tests.clear_authentication();
select throws_ok(
  $$select * from public.restaurant_deletion_plan(current_setting('tests.prazno_id')::uuid)$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot execute restaurant_deletion_plan'
);

-- === Bookings at Brisanje Istorija ===
select tests.authenticate_as('customer_7');
select lives_ok(
  $$select public.create_reservation(
      current_setting('tests.istorija_id')::uuid, 2, (now() + interval '2 hours'), 60
    )$$,
  'customer_7 books a party of 2 at Brisanje Istorija'
);

select lives_ok(
  $$select public.create_reservation(
      current_setting('tests.istorija_id')::uuid, 3, (now() + interval '5 hours'), 60
    )$$,
  'customer_7 books a party of 3 at Brisanje Istorija, later'
);

select tests.authenticate_as('owner_h');
select results_eq(
  $$select active_reservations, cancellable_reservations, total_reservations, staff_count, menu_item_count, table_count
    from public.restaurant_deletion_plan(current_setting('tests.istorija_id')::uuid)$$,
  $$values (2, 2, 2, 1, 0, 0)$$,
  'the plan for Brisanje Istorija shows two active, cancellable reservations'
);

-- === Refused while reservations are active ===
select throws_ok(
  $$select public.delete_restaurant(current_setting('tests.istorija_id')::uuid)$$,
  'P0001',
  'Restoran ima aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.',
  'a restaurant with confirmed reservations cannot be deleted'
);

-- === cancel_all_active_reservations() ===
select tests.authenticate_as('owner_i');
select throws_ok(
  $$select public.cancel_all_active_reservations(current_setting('tests.istorija_id')::uuid)$$,
  'P0001',
  'Restoran ne postoji.',
  'owner_i cannot cancel-all at a restaurant they do not own'
);

select tests.clear_authentication();
select throws_ok(
  $$select public.cancel_all_active_reservations(current_setting('tests.istorija_id')::uuid)$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot execute cancel_all_active_reservations'
);

select tests.authenticate_as_service_role();
update public.reservations set status = 'ongoing'
  where restaurant_id = current_setting('tests.istorija_id')::uuid and party_size = 3;

select tests.authenticate_as('owner_h');
select results_eq(
  $$select public.cancel_all_active_reservations(current_setting('tests.istorija_id')::uuid)$$,
  $$values (1)$$,
  'cancel-all cancels the one cancellable reservation and reports it'
);

select results_eq(
  $$select party_size, status from public.reservations
    where restaurant_id = current_setting('tests.istorija_id')::uuid order by party_size$$,
  $$values (2, 'cancelled'::text), (3, 'ongoing'::text)$$,
  'the party of 2 is cancelled, the ongoing party of 3 is left alone'
);

select ok(
  (select cancelled_by = tests.get_supabase_uid('owner_h')
   from public.reservations
   where restaurant_id = current_setting('tests.istorija_id')::uuid and party_size = 2),
  'the cancellation is recorded as the owner''s (it went through cancel_reservation)'
);

select throws_ok(
  $$select public.delete_restaurant(current_setting('tests.istorija_id')::uuid)$$,
  'P0001',
  'Restoran ima aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.',
  'an ongoing reservation still blocks deletion after cancel-all'
);

select results_eq(
  $$select public.cancel_all_active_reservations(current_setting('tests.istorija_id')::uuid)$$,
  $$values (0)$$,
  'a second cancel-all has nothing left to cancel'
);

select results_eq(
  $$select active_reservations, cancellable_reservations, total_reservations
    from public.restaurant_deletion_plan(current_setting('tests.istorija_id')::uuid)$$,
  $$values (1, 0, 2)$$,
  'the plan now shows one active (ongoing) reservation and nothing cancellable'
);

-- === Direct writes that would skip all of the above are closed off ===
select throws_ok(
  $$delete from public.restaurants where name = 'Brisanje Prazno'$$,
  '42501',
  null,
  'an owner cannot delete their own restaurant with a plain delete'
);

select throws_ok(
  $$update public.restaurants set archived_at = now() where name = 'Brisanje Istorija'$$,
  '42501',
  null,
  'an owner cannot archive their own restaurant with a plain update'
);

select throws_ok(
  $$insert into public.restaurants (owner_id, name, archived_at)
    values (tests.get_supabase_uid('owner_h'), 'Vec Arhiviran', now())$$,
  '42501',
  null,
  'an owner cannot create a restaurant that is already archived'
);

-- === delete_restaurant(): who may call it, and archiving ===
select tests.authenticate_as_service_role();
update public.reservations set status = 'completed'
  where restaurant_id = current_setting('tests.istorija_id')::uuid and party_size = 3;

-- A confirmed reservation whose ends_at has already passed but which the cron
-- sweep hasn't recorded as a no-show yet: it no longer blocks deletion.
select tests.authenticate_as('customer_7');
select lives_ok(
  $$select public.create_reservation(
      current_setting('tests.istorija_id')::uuid, 4, (now() + interval '8 hours'), 60
    )$$,
  'customer_7 books a party of 4, later still'
);

select tests.authenticate_as_service_role();
update public.reservations set starts_at = now() - interval '2 hours', ends_at = now() - interval '1 hour'
  where restaurant_id = current_setting('tests.istorija_id')::uuid and party_size = 4;

select tests.authenticate_as('owner_h');
select results_eq(
  $$select active_reservations, cancellable_reservations, total_reservations
    from public.restaurant_deletion_plan(current_setting('tests.istorija_id')::uuid)$$,
  $$values (0, 0, 3)$$,
  'a confirmed reservation that has already ended (awaiting the sweep) is neither active nor cancellable'
);

select tests.authenticate_as('customer_7');
select throws_ok(
  $$select public.delete_restaurant(current_setting('tests.istorija_id')::uuid)$$,
  'P0001',
  'Restoran ne postoji.',
  'a customer cannot delete a restaurant (even one they have booked at)'
);

select tests.authenticate_as('employee_5');
select throws_ok(
  $$select public.cancel_all_active_reservations(current_setting('tests.istorija_id')::uuid)$$,
  'P0001',
  'Restoran ne postoji.',
  'an employee cannot cancel-all at a restaurant'
);

select tests.authenticate_as('owner_i');
select throws_ok(
  $$select public.delete_restaurant(current_setting('tests.istorija_id')::uuid)$$,
  'P0001',
  'Restoran ne postoji.',
  'owner_i cannot delete a restaurant they do not own'
);

select tests.clear_authentication();
select throws_ok(
  $$select public.delete_restaurant(current_setting('tests.istorija_id')::uuid)$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot execute delete_restaurant'
);

select tests.authenticate_as('owner_h');
select results_eq(
  $$select public.delete_restaurant(current_setting('tests.istorija_id')::uuid)$$,
  $$values ('archived'::text)$$,
  'with no active reservations left, a restaurant that has history is archived, not deleted'
);

select tests.authenticate_as_service_role();
select ok(
  (select archived_at is not null from public.restaurants where id = current_setting('tests.istorija_id')::uuid),
  'the archived restaurant''s row is still there, with archived_at set'
);

select is(
  (select count(*) from public.restaurant_staff where restaurant_id = current_setting('tests.istorija_id')::uuid),
  0::bigint,
  'archiving removed the restaurant''s staff rows'
);

select is(
  (select count(*) from public.orders where restaurant_id = current_setting('tests.istorija_id')::uuid and status = 'draft'),
  0::bigint,
  'archiving removed draft carts at the restaurant'
);

select is(
  (select count(*) from public.reservations where restaurant_id = current_setting('tests.istorija_id')::uuid),
  3::bigint,
  'archiving kept all three reservations'
);

select tests.authenticate_as('customer_7');
select is(
  (select count(*) from public.reservations where restaurant_id = current_setting('tests.istorija_id')::uuid),
  3::bigint,
  'customer_7 can still see their reservations at the archived restaurant'
);

select is(
  (select count(*) from public.restaurants where id = current_setting('tests.istorija_id')::uuid),
  1::bigint,
  'the archived restaurant''s row stays readable, so the customer''s history can still show its name'
);

-- === An archived restaurant takes nothing new ===
select tests.authenticate_as('customer_8');
select throws_ok(
  $$select public.create_reservation(
      current_setting('tests.istorija_id')::uuid, 2, (now() + interval '2 hours'), 60
    )$$,
  'P0001',
  'Restoran ne postoji.',
  'nobody can book at an archived restaurant'
);

select throws_ok(
  $$select public.start_cart(current_setting('tests.istorija_id')::uuid)$$,
  'P0001',
  'Restoran ne postoji.',
  'nobody can start a cart at an archived restaurant'
);

select tests.authenticate_as('employee_5');
select throws_ok(
  $$insert into public.restaurant_staff (restaurant_id, employee_id)
    values (current_setting('tests.istorija_id')::uuid, tests.get_supabase_uid('employee_5'))$$,
  'P0001',
  'Restoran ne postoji.',
  'nobody can apply to work at an archived restaurant'
);

select tests.authenticate_as('owner_h');
select throws_ok(
  $$select public.cancel_all_active_reservations(current_setting('tests.istorija_id')::uuid)$$,
  'P0001',
  'Restoran ne postoji.',
  'cancel-all on an already-archived restaurant is refused'
);

select is_empty(
  $$select * from public.restaurant_deletion_plan(current_setting('tests.istorija_id')::uuid)$$,
  'an archived restaurant has no deletion plan'
);

select throws_ok(
  $$select public.delete_restaurant(current_setting('tests.istorija_id')::uuid)$$,
  'P0001',
  'Restoran ne postoji.',
  'an archived restaurant cannot be deleted again'
);

-- === Hard delete: no reservation history ===
select results_eq(
  $$select public.delete_restaurant(current_setting('tests.prazno_id')::uuid)$$,
  $$values ('deleted'::text)$$,
  'a restaurant with no reservations is really deleted'
);

select tests.authenticate_as_service_role();
select is(
  (select count(*) from public.restaurants where id = current_setting('tests.prazno_id')::uuid),
  0::bigint,
  'the deleted restaurant''s row is gone'
);

select is(
  (select count(*) from public.menu_items where restaurant_id = current_setting('tests.prazno_id')::uuid),
  0::bigint,
  'its menu went with it'
);

select is(
  (select count(*) from public.restaurant_staff where restaurant_id = current_setting('tests.prazno_id')::uuid),
  0::bigint,
  'its applications went with it'
);

select is(
  (select count(*) from public.orders where restaurant_id = current_setting('tests.prazno_id')::uuid),
  0::bigint,
  'the draft cart at it went with it'
);

select is(
  (select count(*) from public.order_items),
  0::bigint,
  'and so did the cart''s item (the cascade got through order_items while its menu item was being removed)'
);

select is(
  (select count(*) from public.tables where restaurant_id = current_setting('tests.prazno_id')::uuid)
    + (select count(*) from public.sections where restaurant_id = current_setting('tests.prazno_id')::uuid)
    + (select count(*) from public.layouts where restaurant_id = current_setting('tests.prazno_id')::uuid),
  0::bigint,
  'its layout, section and table went with it (the delete guards did not get in the way)'
);

select * from finish();
rollback;
