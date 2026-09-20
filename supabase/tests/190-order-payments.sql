-- Coverage for supabase/migrations/20260920160000_order_payments.sql (Stripe
-- test-mode payments):
-- * the payment columns can't be written from the client, and the three
--   payment-state functions (set_order_checkout_session / mark_order_paid /
--   mark_order_refunded) are executable by service_role only - i.e. by the
--   Edge Functions, never by a signed-in user;
-- * mark_order_paid() is idempotent, reports a second, different payment for an
--   already-paid order as a duplicate (the webhook refunds it), and turns a
--   payment that lands after the order was cancelled into a pending refund;
-- * a pending refund blocks deleting the account or restaurant that could
--   retry it (delete_my_account / delete_restaurant);
-- * cancel_reservation() applies the refund policy in the same transaction:
--   the restaurant's owner cancelling always queues a refund of a paid order;
--   a customer cancelling queues it only while the reservation is still
--   'confirmed' (not once the kitchen is preparing); an unpaid order has
--   nothing to refund.
--
-- Pay Kapacitet (owner_h) is a plain-capacity restaurant (15 seats, 24/7) with
-- one menu item. Five reservations, each with an order, told apart by party_size:
--   1 (customer_7)  R1: paid, still confirmed, cancelled by its customer -> refund_pending
--   2 (customer_7)  R2: paid, preparing_order, cancelled by its customer -> stays paid
--   3 (customer_8)  R3: paid, preparing_order, cancelled by the owner -> refund_pending
--   4 (customer_8)  R4: never paid, cancelled by its customer -> stays unpaid
--   5 (customer_7)  R5: checkout session open (unpaid), cancelled, then the
--                       payment lands late -> refund_pending -> refunded
-- Every order is given a checkout session first, as create-checkout would.
begin;
select plan(25);

select tests.create_supabase_user('owner_h', 'ownerh@test.com', null,
  '{"first_name":"Owner","last_name":"H","phone":"555-0041","role":"owner"}'::jsonb);
select tests.create_supabase_user('customer_7', 'customer7@test.com', null,
  '{"first_name":"Cust","last_name":"Seven","phone":"555-0042","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_8', 'customer8@test.com', null,
  '{"first_name":"Cust","last_name":"Eight","phone":"555-0043","role":"customer"}'::jsonb);

select tests.authenticate_as('owner_h');
insert into public.restaurants (owner_id, name, capacity)
  values (tests.get_supabase_uid('owner_h'), 'Pay Kapacitet', 15);
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'Pay Kapacitet'), d, 0, 1440
  from generate_series(0, 6) as d;
insert into public.menu_items (restaurant_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'Pay Kapacitet'), 'Pica P', 500, true);

-- Five bookings with a cart each. A DO block so the per-booking identity
-- switch and the start_cart -> add_order_item -> create_reservation sequence
-- stay in one place; it ends back on the test's own role.
select tests.authenticate_as_service_role();
do $$
declare
  v_rest uuid := (select id from public.restaurants where name = 'Pay Kapacitet');
  v_item uuid := (select id from public.menu_items where name = 'Pica P');
  v_customers text[] := array['customer_7', 'customer_7', 'customer_8', 'customer_8', 'customer_7'];
  v_i int;
  v_uid uuid;
  v_order uuid;
begin
  for v_i in 1..5 loop
    v_uid := tests.get_supabase_uid(v_customers[v_i]);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.start_cart(v_rest);
    select id into v_order from public.orders where customer_id = v_uid and status = 'draft';
    perform public.add_order_item(v_order, v_item);
    perform public.create_reservation(v_rest, v_i, now() + ((v_i * 3) || ' hours')::interval, 60, null, null, v_order);
    execute 'reset role';
  end loop;
end $$;

select tests.authenticate_as_service_role();
select public.set_order_checkout_session(o.id, 'cs_' || o.id)
from public.orders o
join public.reservations r on r.id = o.reservation_id
where r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet');

-- === mark_order_paid ===
select is(
  (select public.mark_order_paid(o.id, 'cs_' || o.id, 'pi_r1') from public.orders o
    join public.reservations r on r.id = o.reservation_id
    where r.party_size = 1 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'paid',
  'mark_order_paid marks R1''s order paid'
);
select is(
  (select public.mark_order_paid(o.id, 'cs_' || o.id, 'pi_r2') from public.orders o
    join public.reservations r on r.id = o.reservation_id
    where r.party_size = 2 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'paid',
  'mark_order_paid marks R2''s order paid'
);
select is(
  (select public.mark_order_paid(o.id, 'cs_' || o.id, 'pi_r3') from public.orders o
    join public.reservations r on r.id = o.reservation_id
    where r.party_size = 3 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'paid',
  'mark_order_paid marks R3''s order paid'
);
select is(
  (select public.mark_order_paid(o.id, 'cs_' || o.id, 'pi_r1') from public.orders o
    join public.reservations r on r.id = o.reservation_id
    where r.party_size = 1 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'paid',
  'a repeated webhook for R1 is a no-op that reports the current state'
);
select is(
  (select public.mark_order_paid(o.id, 'cs_second_session', 'pi_second') from public.orders o
    join public.reservations r on r.id = o.reservation_id
    where r.party_size = 1 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'duplicate',
  'a second, different payment for an already-paid order is reported as a duplicate (the webhook refunds it); R4 stays unpaid'
);

-- R2 and R3 are now being prepared by the kitchen.
update public.reservations set status = 'preparing_order'
where party_size in (2, 3) and restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet');

-- === Refund policy in cancel_reservation() ===
select tests.authenticate_as('customer_7');
select lives_ok(
  $$select public.cancel_reservation((select id from public.reservations where party_size = 1 and restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')))$$,
  'customer_7 cancels R1 (paid, still confirmed)'
);
select lives_ok(
  $$select public.cancel_reservation((select id from public.reservations where party_size = 2 and restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')))$$,
  'customer_7 cancels R2 (paid, preparing_order)'
);
select lives_ok(
  $$select public.cancel_reservation((select id from public.reservations where party_size = 5 and restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')))$$,
  'customer_7 cancels R5 (checkout session open, unpaid)'
);

select tests.authenticate_as('owner_h');
select lives_ok(
  $$select public.cancel_reservation((select id from public.reservations where party_size = 3 and restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')))$$,
  'owner_h cancels R3 (paid, preparing_order)'
);

select tests.authenticate_as('customer_8');
select lives_ok(
  $$select public.cancel_reservation((select id from public.reservations where party_size = 4 and restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')))$$,
  'customer_8 cancels R4 (never paid)'
);

select tests.authenticate_as_service_role();
select is(
  (select o.payment_status from public.orders o join public.reservations r on r.id = o.reservation_id
    where r.party_size = 1 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'refund_pending',
  'R1: a customer cancelling while confirmed queues a refund'
);
select is(
  (select o.payment_status from public.orders o join public.reservations r on r.id = o.reservation_id
    where r.party_size = 2 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'paid',
  'R2: a customer cancelling during preparation keeps the payment (no refund)'
);
select is(
  (select o.payment_status from public.orders o join public.reservations r on r.id = o.reservation_id
    where r.party_size = 3 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'refund_pending',
  'R3: the owner cancelling always queues a refund, even during preparation'
);
select is(
  (select o.payment_status from public.orders o join public.reservations r on r.id = o.reservation_id
    where r.party_size = 4 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'unpaid',
  'R4: an unpaid order has nothing to refund'
);
select is(
  (select o.payment_status from public.orders o join public.reservations r on r.id = o.reservation_id
    where r.party_size = 5 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'unpaid',
  'R5: cancelling with a checkout session open leaves the order unpaid'
);

-- === Payment landing after a cancellation ===
select is(
  (select public.mark_order_paid(o.id, 'cs_' || o.id, 'pi_r5') from public.orders o
    join public.reservations r on r.id = o.reservation_id
    where r.party_size = 5 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'refund_pending',
  'R5: a payment that arrives after the cancellation becomes a pending refund'
);
select lives_ok(
  $$select public.mark_order_refunded((select o.id from public.orders o join public.reservations r on r.id = o.reservation_id
      where r.party_size = 5 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')))$$,
  'mark_order_refunded runs for R5'
);
select is(
  (select o.payment_status from public.orders o join public.reservations r on r.id = o.reservation_id
    where r.party_size = 5 and r.restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  'refunded',
  'R5 is refunded'
);

-- === Privileges ===
select tests.authenticate_as('customer_7');
select throws_ok(
  $$select public.mark_order_paid(gen_random_uuid(), 'cs_x', 'pi_x')$$,
  '42501',
  null,
  'an authenticated user cannot call mark_order_paid'
);
select throws_ok(
  $$update public.orders set payment_status = 'paid' where reservation_id is not null$$,
  '42501',
  null,
  'an authenticated user cannot write payment_status'
);
select throws_ok(
  $$select public.set_order_checkout_session(gen_random_uuid(), 'cs_x')$$,
  '42501',
  null,
  'an authenticated user cannot call set_order_checkout_session'
);
select throws_ok(
  $$select public.mark_order_refunded(gen_random_uuid())$$,
  '42501',
  null,
  'an authenticated user cannot call mark_order_refunded'
);

-- === A pending refund blocks deleting the account / restaurant that could retry it ===
-- customer_7 still has R1 in refund_pending; owner_h's restaurant has R1 and R3.
select throws_ok(
  $$select public.delete_my_account()$$,
  'P0001',
  'Imate povraćaj novca koji je u toku. Završite ga (dugme "Ponovi povraćaj novca" na listi rezervacija), pa pokušajte ponovo.',
  'customer_7 cannot delete their account while a refund is pending'
);

select tests.authenticate_as('owner_h');
select throws_ok(
  $$select public.delete_restaurant((select id from public.restaurants where name = 'Pay Kapacitet'))$$,
  'P0001',
  'Restoran ima povraćaje novca koji su u toku. Završite ih (dugme "Ponovi povraćaj novca" na listi rezervacija), pa pokušajte ponovo.',
  'owner_h cannot delete a restaurant while a refund is pending'
);

select tests.clear_authentication();
select throws_ok(
  $$select public.mark_order_paid(gen_random_uuid(), 'cs_x', 'pi_x')$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot call mark_order_paid'
);

select * from finish();
rollback;
