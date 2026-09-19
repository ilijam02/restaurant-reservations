-- Coverage for supabase/migrations/20260919100000_cancel_reservation.sql and
-- 20260919110000_cancel_reservation_audit.sql (cancelled_at/cancelled_by,
-- and update_reservation_status() saying "cancelled" instead of a misleading
-- transition error on a cancelled reservation):
-- cancel_reservation() - who may call it (the booking customer and the
-- restaurant's owner, nobody else, no anon), which statuses it accepts
-- (confirmed / preparing_order / order_prepared only, and never an
-- already-expired reservation), that it cancels the linked order too, and
-- that it actually frees the table slot: the reservation_tables rows become
-- an empty range (starts_at = ends_at = now()) so the exclusion constraint
-- can never fire on them, even against another reservation running on the
-- same table right now. Also the two read-side additions the owner's
-- reservations list needs: owners can read the profile of a customer who
-- reserved at their restaurant, and can keep reading an order after it's
-- cancelled.
--
-- Cancel Café (owner_f) has three 8-seat tables (C1-C3) on an active layout,
-- 24/7 hours and a single no-options menu item "Pica C". employee_4 is
-- accepted staff there (inserted as service_role, skipping the apply/accept
-- dance covered by 20-restaurant-staff-rls.sql). owner_g owns nothing
-- relevant - just "an owner who isn't this restaurant's owner".
--
-- Reservations are told apart by party_size:
--   1 (customer_6)  F: on C3, backdated to be running right now
--   2 (customer_5)  A: on C1, plain, cancelled by its customer
--   3 (customer_5)  B: on C2, with an order, cancelled by the owner
--   4 (customer_5)  G: on C3 in the future, set to order_prepared, cancelled
--                      while F is running on that same table
--   5 (customer_6)  D: status gates (ongoing/completed/no_show/cancelled)
--   6 (customer_6)  E: already expired
--   7 (customer_6)  rebooks A's freed slot on C1
-- Times are relative to now() and "already started/expired" is simulated
-- with a service_role backdate, same as 80-reservation-status-lifecycle.sql.
begin;
select plan(46);

select tests.create_supabase_user('owner_f', 'ownerf@test.com', null,
  '{"first_name":"Owner","last_name":"F","phone":"555-0021","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_g', 'ownerg@test.com', null,
  '{"first_name":"Owner","last_name":"G","phone":"555-0022","role":"owner"}'::jsonb);
select tests.create_supabase_user('employee_4', 'employee4@test.com', null,
  '{"first_name":"Emp","last_name":"Four","phone":"555-0023","role":"employee"}'::jsonb);
select tests.create_supabase_user('customer_5', 'customer5@test.com', null,
  '{"first_name":"Cust","last_name":"Five","phone":"555-0024","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_6', 'customer6@test.com', null,
  '{"first_name":"Cust","last_name":"Six","phone":"555-0025","role":"customer"}'::jsonb);

select tests.authenticate_as('owner_f');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_f'), 'Cancel Café');
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'Cancel Café'), d, 0, 1440
  from generate_series(0, 6) as d;
insert into public.layouts (restaurant_id, name, is_active)
  values ((select id from public.restaurants where name = 'Cancel Café'), 'Raspored', true);
insert into public.tables (restaurant_id, layout_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'Cancel Café'),
    (select id from public.layouts where name = 'Raspored'),
    'Sto C1', 8, 0, 0, 2, 2
  );
insert into public.tables (restaurant_id, layout_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'Cancel Café'),
    (select id from public.layouts where name = 'Raspored'),
    'Sto C2', 8, 4, 0, 2, 2
  );
insert into public.tables (restaurant_id, layout_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'Cancel Café'),
    (select id from public.layouts where name = 'Raspored'),
    'Sto C3', 8, 8, 0, 2, 2
  );
insert into public.menu_items (restaurant_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'Cancel Café'), 'Pica C', 500, true);

-- A second restaurant in plain-capacity mode (no layout, no sections): 4
-- seats, 24/7, used only for the "cancelling frees capacity" check.
insert into public.restaurants (owner_id, name, capacity)
  values (tests.get_supabase_uid('owner_f'), 'Cancel Kapacitet', 4);
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'Cancel Kapacitet'), d, 0, 1440
  from generate_series(0, 6) as d;

select tests.authenticate_as_service_role();
insert into public.restaurant_staff (restaurant_id, employee_id, status)
  values (
    (select id from public.restaurants where name = 'Cancel Café'),
    tests.get_supabase_uid('employee_4'),
    'accepted'
  );

-- === Setup bookings ===
select tests.authenticate_as('customer_5');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'Cancel Café'),
      2, (now() + interval '2 hours'), 60, null,
      array[(select id from public.tables where name = 'Sto C1')]
    )$$,
  'customer_5 books A (party 2) on Sto C1, 2 hours out, no order'
);

select lives_ok(
  $$select public.start_cart((select id from public.restaurants where name = 'Cancel Café'))$$,
  'customer_5 starts a cart at Cancel Café'
);

select lives_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_5') and status = 'draft'),
      (select id from public.menu_items where name = 'Pica C')
    )$$,
  'customer_5 adds Pica C to the cart'
);

select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'Cancel Café'),
      3, (now() + interval '2 hours'), 60, null,
      array[(select id from public.tables where name = 'Sto C2')],
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_5') and status = 'draft')
    )$$,
  'customer_5 books B (party 3) on Sto C2 with the cart attached'
);

select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'Cancel Café'),
      4, (now() + interval '2 hours'), 60, null,
      array[(select id from public.tables where name = 'Sto C3')]
    )$$,
  'customer_5 books G (party 4) on Sto C3, 2 hours out'
);

select tests.authenticate_as('customer_6');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'Cancel Café'),
      1, (now() + interval '20 minutes'), 30, null,
      array[(select id from public.tables where name = 'Sto C3')]
    )$$,
  'customer_6 books F (party 1) on Sto C3, 20 minutes out - it will be backdated to be running right now'
);

select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'Cancel Café'),
      5, (now() + interval '5 hours'), 60, null,
      array[(select id from public.tables where name = 'Sto C3')]
    )$$,
  'customer_6 books D (party 5) on Sto C3, 5 hours out'
);

select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'Cancel Café'),
      6, (now() + interval '8 hours'), 60, null,
      array[(select id from public.tables where name = 'Sto C1')]
    )$$,
  'customer_6 books E (party 6) on Sto C1, 8 hours out - it will be backdated to already be over'
);

-- Backdate F to be running right now (reservation and its table row both, so
-- the two stay consistent) and E to be already over; move G to
-- order_prepared. Then stash every reservation id in transaction-local
-- settings: several callers below can't see the reservation they're
-- attempting to cancel, so a subselect run as them would come back null and
-- the call would fail on "doesn't exist" instead of reaching the case under
-- test.
select tests.authenticate_as_service_role();
update public.reservations
  set starts_at = now() - interval '10 minutes', ends_at = now() + interval '20 minutes'
  where restaurant_id = (select id from public.restaurants where name = 'Cancel Café') and party_size = 1;
update public.reservation_tables
  set starts_at = now() - interval '10 minutes', ends_at = now() + interval '20 minutes'
  where reservation_id = (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'Cancel Café') and party_size = 1);
update public.reservations
  set starts_at = now() - interval '2 hours', ends_at = now() - interval '1 hour'
  where restaurant_id = (select id from public.restaurants where name = 'Cancel Café') and party_size = 6;
update public.reservations set status = 'order_prepared'
  where restaurant_id = (select id from public.restaurants where name = 'Cancel Café') and party_size = 4;

select set_config('tests.a_id', (select id::text from public.reservations where restaurant_id = (select id from public.restaurants where name = 'Cancel Café') and party_size = 2), true);
select set_config('tests.b_id', (select id::text from public.reservations where restaurant_id = (select id from public.restaurants where name = 'Cancel Café') and party_size = 3), true);
select set_config('tests.g_id', (select id::text from public.reservations where restaurant_id = (select id from public.restaurants where name = 'Cancel Café') and party_size = 4), true);
select set_config('tests.d_id', (select id::text from public.reservations where restaurant_id = (select id from public.restaurants where name = 'Cancel Café') and party_size = 5), true);
select set_config('tests.e_id', (select id::text from public.reservations where restaurant_id = (select id from public.restaurants where name = 'Cancel Café') and party_size = 6), true);

-- === Status gates: D moves through statuses that can't be cancelled ===
update public.reservations set status = 'ongoing' where id = current_setting('tests.d_id')::uuid;
select tests.authenticate_as('customer_6');
select throws_ok(
  $$select public.cancel_reservation(current_setting('tests.d_id')::uuid)$$,
  'P0001',
  'Rezervacija može biti otkazana samo dok je potvrđena ili se porudžbina priprema.',
  'an ongoing reservation (guest already seated) cannot be cancelled'
);

select tests.authenticate_as_service_role();
update public.reservations set status = 'completed' where id = current_setting('tests.d_id')::uuid;
select tests.authenticate_as('customer_6');
select throws_ok(
  $$select public.cancel_reservation(current_setting('tests.d_id')::uuid)$$,
  'P0001',
  'Rezervacija može biti otkazana samo dok je potvrđena ili se porudžbina priprema.',
  'a completed reservation cannot be cancelled'
);

select tests.authenticate_as_service_role();
update public.reservations set status = 'no_show' where id = current_setting('tests.d_id')::uuid;
select tests.authenticate_as('customer_6');
select throws_ok(
  $$select public.cancel_reservation(current_setting('tests.d_id')::uuid)$$,
  'P0001',
  'Rezervacija može biti otkazana samo dok je potvrđena ili se porudžbina priprema.',
  'a no_show reservation cannot be cancelled'
);

select tests.authenticate_as_service_role();
update public.reservations set status = 'cancelled' where id = current_setting('tests.d_id')::uuid;
select tests.authenticate_as('customer_6');
select throws_ok(
  $$select public.cancel_reservation(current_setting('tests.d_id')::uuid)$$,
  'P0001',
  'Rezervacija može biti otkazana samo dok je potvrđena ili se porudžbina priprema.',
  'an already-cancelled reservation cannot be cancelled again'
);

select throws_ok(
  $$select public.cancel_reservation(current_setting('tests.e_id')::uuid)$$,
  'P0001',
  'Rezervacija je već istekla.',
  'a reservation whose ends_at has passed cannot be cancelled, even before the cron sweep has recorded it as a no-show'
);

-- === Permissions, on A (customer_5's plain reservation) ===
select throws_ok(
  $$select public.cancel_reservation(current_setting('tests.a_id')::uuid)$$,
  'P0001',
  'Rezervacija ne postoji.',
  'customer_6 cannot cancel customer_5''s reservation (same message as a missing id, so ids can''t be probed)'
);

select tests.authenticate_as('employee_4');
select throws_ok(
  $$select public.cancel_reservation(current_setting('tests.a_id')::uuid)$$,
  'P0001',
  'Rezervacija ne postoji.',
  'employee_4, accepted staff at the restaurant, cannot cancel - only the customer and the owner can'
);

select tests.authenticate_as('owner_g');
select throws_ok(
  $$select public.cancel_reservation(current_setting('tests.a_id')::uuid)$$,
  'P0001',
  'Rezervacija ne postoji.',
  'owner_g, who does not own Cancel Café, cannot cancel its reservations'
);

select tests.clear_authentication();
select throws_ok(
  $$select public.cancel_reservation(gen_random_uuid())$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot execute cancel_reservation at all'
);

-- === A: customer cancels their own plain reservation ===
select tests.authenticate_as('customer_5');
select lives_ok(
  $$select public.cancel_reservation(current_setting('tests.a_id')::uuid)$$,
  'customer_5 cancels their own confirmed reservation A'
);

select results_eq(
  $$select status from public.reservations where id = current_setting('tests.a_id')::uuid$$,
  $$values ('cancelled'::text)$$,
  'A is now cancelled'
);

select ok(
  (select cancelled_by = tests.get_supabase_uid('customer_5') and cancelled_at = now()
   from public.reservations where id = current_setting('tests.a_id')::uuid),
  'A records who cancelled it (customer_5) and when'
);

select tests.authenticate_as_service_role();
select ok(
  (select bool_and(starts_at = ends_at and ends_at <= now())
   from public.reservation_tables where reservation_id = current_setting('tests.a_id')::uuid),
  'A''s reservation_tables range collapsed to an empty range at now() (starts_at = ends_at, so never starts_at > ends_at)'
);

select ok(
  (select starts_at > now() and ends_at > starts_at
   from public.reservations where id = current_setting('tests.a_id')::uuid),
  'A''s own reservations row keeps its booked (future) starts_at/ends_at'
);

select tests.authenticate_as('customer_6');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'Cancel Café'),
      7, (now() + interval '2 hours'), 60, null,
      array[(select id from public.tables where name = 'Sto C1')]
    )$$,
  'customer_6 books the exact table and time A held - only possible because cancelling freed A''s reservation_tables slot (a status change alone would not have)'
);

select tests.authenticate_as('customer_5');
select throws_ok(
  $$select public.cancel_reservation(current_setting('tests.a_id')::uuid)$$,
  'P0001',
  'Rezervacija može biti otkazana samo dok je potvrđena ili se porudžbina priprema.',
  'cancelling A a second time is rejected'
);

-- === B: owner cancels a reservation whose order is being prepared ===
select tests.authenticate_as('employee_4');
select lives_ok(
  $$select public.update_reservation_status(current_setting('tests.b_id')::uuid, 'preparing_order')$$,
  'employee_4 starts preparing B''s order'
);

select tests.authenticate_as('owner_f');
select lives_ok(
  $$select public.cancel_reservation(current_setting('tests.b_id')::uuid)$$,
  'owner_f cancels customer_5''s reservation B while its order is being prepared'
);

select results_eq(
  $$select r.status, o.status
    from public.reservations r join public.orders o on o.reservation_id = r.id
    where r.id = current_setting('tests.b_id')::uuid$$,
  $$values ('cancelled'::text, 'cancelled'::text)$$,
  'cancelling B cancelled its linked order too (and owner_f can still read that cancelled order)'
);

select is(
  (select count(*) from public.order_items
   where order_id = (select id from public.orders where reservation_id = current_setting('tests.b_id')::uuid)),
  1::bigint,
  'owner_f can still read the items of B''s cancelled order'
);

select ok(
  (select cancelled_by = tests.get_supabase_uid('owner_f') and cancelled_at = now()
   from public.reservations where id = current_setting('tests.b_id')::uuid),
  'B records who cancelled it (owner_f, not the customer) and when'
);

select tests.authenticate_as('employee_4');
select throws_ok(
  $$select public.update_reservation_status(current_setting('tests.b_id')::uuid, 'order_prepared')$$,
  'P0001',
  'Rezervacija je otkazana.',
  'staff acting on a stale card get told the reservation was cancelled, not a misleading transition error'
);

select tests.authenticate_as('owner_g');
select is(
  (select count(*) from public.orders where status = 'cancelled'),
  0::bigint,
  'owner_g cannot see cancelled orders at a restaurant they do not own'
);

select is(
  (select count(*) from public.order_items),
  0::bigint,
  'owner_g cannot see the items of a cancelled order at a restaurant they do not own either'
);

select tests.authenticate_as('employee_4');
select is(
  (select count(*) from public.orders where status = 'cancelled'),
  0::bigint,
  'employee_4 (accepted staff) cannot see cancelled orders - only owners got that read access'
);

select is(
  (select count(*) from public.order_items),
  0::bigint,
  'employee_4 cannot see the items of a cancelled order either'
);

select tests.authenticate_as('customer_5');
select is(
  (select count(*) from public.orders where status = 'cancelled' and reservation_id = current_setting('tests.b_id')::uuid),
  1::bigint,
  'customer_5 still sees their own cancelled order'
);

-- === G: order_prepared is cancellable, and cancelling a future reservation
-- === must not collide with F, which is running on the same table right now ===
select lives_ok(
  $$select public.cancel_reservation(current_setting('tests.g_id')::uuid)$$,
  'customer_5 cancels G (order_prepared) on Sto C3 while F is running on Sto C3 - the emptied range overlaps nothing, so no exclusion violation'
);

select results_eq(
  $$select status from public.reservations where id = current_setting('tests.g_id')::uuid$$,
  $$values ('cancelled'::text)$$,
  'G is now cancelled'
);

-- === The table-based cancels above are now visible to the availability preview ===
select is(
  (select array_agg(t.name order by t.name)
   from public.get_occupied_table_ids(
     (select id from public.restaurants where name = 'Cancel Café'),
     now() + interval '2 hours',
     now() + interval '3 hours'
   ) o join public.tables t on t.id = o.table_id),
  array['Sto C1']::text[],
  'get_occupied_table_ids reports only Sto C1 (customer_6''s rebooking of A''s slot) as taken in that window - B''s Sto C2 and G''s Sto C3 are free again'
);

-- === Plain-capacity restaurant (no layout, no sections): cancelling frees
-- === capacity, not just table slots ===
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'Cancel Kapacitet'),
      4, (now() + interval '2 hours'), 60
    )$$,
  'customer_5 books a party of 4 at Cancel Kapacitet (capacity 4, no layout or sections) - the restaurant is now full for that slot'
);

select tests.authenticate_as('customer_6');
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'Cancel Kapacitet'),
      1, (now() + interval '2 hours'), 60
    )$$,
  'P0001',
  'Nema dovoljno slobodnih mesta u izabrano vreme (slobodno mesta: 0).',
  'customer_6 cannot book even one more seat in that slot while the party of 4 is confirmed'
);

select tests.authenticate_as('customer_5');
select lives_ok(
  $$select public.cancel_reservation(
      (select id from public.reservations where restaurant_id = (select id from public.restaurants where name = 'Cancel Kapacitet'))
    )$$,
  'customer_5 cancels the party of 4 at Cancel Kapacitet'
);

select tests.authenticate_as('customer_6');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'Cancel Kapacitet'),
      1, (now() + interval '2 hours'), 60
    )$$,
  'customer_6 can now book that slot - cancelling freed the plain capacity too'
);

-- === Owner-side read access to customer profiles ===
select tests.authenticate_as('owner_f');
select is(
  (select count(*) from public.profiles
   where id in (tests.get_supabase_uid('customer_5'), tests.get_supabase_uid('customer_6'))),
  2::bigint,
  'owner_f can read the profiles of both customers who reserved at Cancel Café'
);

select tests.authenticate_as('owner_g');
select is(
  (select count(*) from public.profiles
   where id in (tests.get_supabase_uid('customer_5'), tests.get_supabase_uid('customer_6'))),
  0::bigint,
  'owner_g cannot read the profiles of customers who never reserved at their restaurant'
);

select tests.authenticate_as('customer_6');
select is(
  (select count(*) from public.profiles where id = tests.get_supabase_uid('customer_5')),
  0::bigint,
  'a customer still cannot read another customer''s profile'
);

select tests.authenticate_as('employee_4');
select is(
  (select count(*) from public.profiles where id = tests.get_supabase_uid('customer_5')),
  0::bigint,
  'staff cannot read customer profiles either - only the owner''s policy was added'
);

select * from finish();
rollback;
