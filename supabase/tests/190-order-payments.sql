-- Coverage for the Stripe test-mode payment flow: pay first, book after
-- (supabase/migrations/20260920160000_order_payments.sql, revised by
-- 20260920170000_order_payments_review_fixes.sql and
-- 20260921100000_pay_before_booking.sql):
-- * validate_booking() is a dry run: it applies create_reservation()'s rules and
--   errors but keeps nothing;
-- * finalize_paid_booking() - what the payment webhook calls - creates the
--   reservation for the paying customer and marks the order paid, in one step;
--   a booking that can't be made after the payment (time passed, cart edited
--   while paying) creates NO reservation and reports 'failed' so the payment is
--   refunded; a replay is a no-op ('replay') and a payment nothing is waiting
--   for ('stray') is reported so it can be refunded;
-- * cancel_reservation() applies the refund policy in the same transaction: the
--   restaurant's owner cancelling always queues a refund of a paid order; a
--   customer cancelling queues it only while the reservation is still
--   'confirmed' (not once the kitchen is preparing);
-- * the payment-state functions are executable by service_role only, and the
--   payment columns can't be written from the client;
-- * a pending refund blocks deleting the account or restaurant that could retry
--   it (delete_my_account / delete_restaurant).
--
-- Pay Kapacitet (owner_h) is a plain-capacity restaurant (15 seats, 24/7) with
-- one menu item. Five customers each have a cart, priced at 500 (50000 para) and
-- put "awaiting payment" as create-checkout would (set_order_pending_booking):
--   customer_7   paid, booked, then cancelled by the customer while confirmed -> refund_pending
--   customer_8   paid, booked, preparing_order, cancelled by the customer -> stays paid
--   customer_9   paid, booked, preparing_order, cancelled by the owner -> refund_pending
--   customer_10  paid, but the booking time is in the past -> failed, no reservation
--   customer_11  paid, but the cart was edited after pricing -> failed, no reservation
begin;
select plan(32);

select tests.create_supabase_user('owner_h', 'ownerh@test.com', null,
  '{"first_name":"Owner","last_name":"H","phone":"555-0041","role":"owner"}'::jsonb);
select tests.create_supabase_user('customer_7', 'customer7@test.com', null,
  '{"first_name":"Cust","last_name":"Seven","phone":"555-0042","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_8', 'customer8@test.com', null,
  '{"first_name":"Cust","last_name":"Eight","phone":"555-0043","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_9', 'customer9@test.com', null,
  '{"first_name":"Cust","last_name":"Nine","phone":"555-0044","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_10', 'customer10@test.com', null,
  '{"first_name":"Cust","last_name":"Ten","phone":"555-0045","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_11', 'customer11@test.com', null,
  '{"first_name":"Cust","last_name":"Eleven","phone":"555-0046","role":"customer"}'::jsonb);

select tests.authenticate_as('owner_h');
insert into public.restaurants (owner_id, name, capacity)
  values (tests.get_supabase_uid('owner_h'), 'Pay Kapacitet', 15);
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'Pay Kapacitet'), d, 0, 1440
  from generate_series(0, 6) as d;
insert into public.menu_items (restaurant_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'Pay Kapacitet'), 'Pica P', 500, true);

-- Five carts, each put "awaiting payment". A DO block so the per-customer
-- identity switch and the start_cart -> add_order_item -> (as the checkout
-- function) set_order_pending_booking sequence stay in one place. customer_10's
-- booking time is in the past; customer_11 adds a second item after the session
-- was priced, so the cart no longer adds up to what was charged.
select tests.authenticate_as_service_role();
do $$
declare
  v_rest uuid := (select id from public.restaurants where name = 'Pay Kapacitet');
  v_item uuid := (select id from public.menu_items where name = 'Pica P');
  v_customers text[] := array['customer_7', 'customer_8', 'customer_9', 'customer_10', 'customer_11'];
  v_i int;
  v_uid uuid;
  v_order uuid;
  v_start text;
begin
  for v_i in 1..5 loop
    v_uid := tests.get_supabase_uid(v_customers[v_i]);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.start_cart(v_rest);
    select id into v_order from public.orders where customer_id = v_uid and status = 'draft';
    perform public.add_order_item(v_order, v_item);
    execute 'reset role';

    v_start := case
      when v_customers[v_i] = 'customer_10' then to_char(now() - interval '1 day', 'YYYY-MM-DD"T"HH24:MI:SSOF')
      else to_char(now() + ((v_i * 3) || ' hours')::interval, 'YYYY-MM-DD"T"HH24:MI:SSOF')
    end;
    perform public.set_order_pending_booking(
      v_order, 'cs_' || v_order,
      jsonb_build_object('party_size', 1, 'starts_at', v_start, 'stay_minutes', 60, 'section_id', null, 'table_ids', null),
      50000
    );

    if v_customers[v_i] = 'customer_11' then
      perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      perform public.add_order_item(v_order, v_item);
      execute 'reset role';
    end if;
  end loop;
end $$;

-- === validate_booking: a dry run ===
select tests.authenticate_as('customer_7');
select lives_ok(
  $$select public.validate_booking(
      (select id from public.restaurants where name = 'Pay Kapacitet'),
      2, now() + interval '3 hours', 60, null, null,
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_7'))
    )$$,
  'validate_booking accepts a valid booking request'
);
select tests.authenticate_as_service_role();
select is(
  (select count(*)::integer from public.reservations where restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  0,
  'a dry run creates no reservation'
);
select is(
  (select status from public.orders where customer_id = tests.get_supabase_uid('customer_7')),
  'draft',
  'a dry run leaves the cart a draft'
);
select tests.authenticate_as('customer_7');
select throws_ok(
  $$select public.validate_booking(
      (select id from public.restaurants where name = 'Pay Kapacitet'),
      2, now() - interval '1 day', 60, null, null, null
    )$$,
  'P0001',
  'Rezervacija mora biti u budućnosti.',
  'validate_booking refuses a booking in the past with the booking rules'' own message'
);

-- === finalize_paid_booking: what the payment webhook calls ===
select tests.authenticate_as_service_role();
select is(
  (select public.finalize_paid_booking(o.id, 'cs_' || o.id, 'pi_c7') from public.orders o
    where o.customer_id = tests.get_supabase_uid('customer_7')),
  'booked',
  'a paid, valid booking is created (customer_7)'
);
select is(
  (select public.finalize_paid_booking(o.id, 'cs_' || o.id, 'pi_c8') from public.orders o
    where o.customer_id = tests.get_supabase_uid('customer_8')),
  'booked',
  'a paid, valid booking is created (customer_8)'
);
select is(
  (select public.finalize_paid_booking(o.id, 'cs_' || o.id, 'pi_c9') from public.orders o
    where o.customer_id = tests.get_supabase_uid('customer_9')),
  'booked',
  'a paid, valid booking is created (customer_9)'
);
select is(
  (select public.finalize_paid_booking(o.id, 'cs_' || o.id, 'pi_c10') from public.orders o
    where o.customer_id = tests.get_supabase_uid('customer_10')),
  'failed',
  'a paid booking whose time has passed fails (customer_10) - the webhook refunds it'
);
select is(
  (select public.finalize_paid_booking(o.id, 'cs_' || o.id, 'pi_c11') from public.orders o
    where o.customer_id = tests.get_supabase_uid('customer_11')),
  'failed',
  'a paid booking whose cart was edited after pricing fails (customer_11) - the webhook refunds it'
);
select is(
  (select count(*)::integer from public.reservations where restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  3,
  'only the three successful payments created reservations'
);
select is(
  (select r.customer_id from public.reservations r join public.orders o on o.reservation_id = r.id
    where o.customer_id = tests.get_supabase_uid('customer_7')),
  tests.get_supabase_uid('customer_7'),
  'the reservation belongs to the paying customer, not to the webhook'
);
select is(
  (select payment_status from public.orders where customer_id = tests.get_supabase_uid('customer_7')),
  'paid',
  'the booked order is confirmed and paid'
);
select is(
  (select booking_failure from public.orders where customer_id = tests.get_supabase_uid('customer_10')),
  'Rezervacija mora biti u budućnosti.',
  'the failed booking records why (the booking rules'' message), and customer_10 has no reservation'
);
select is(
  (select booking_failure from public.orders where customer_id = tests.get_supabase_uid('customer_11')),
  'Porudžbina je izmenjena tokom plaćanja.',
  'the tampered cart records why, and customer_11 has no reservation'
);
select is(
  (select public.finalize_paid_booking(o.id, 'cs_' || o.id, 'pi_c7') from public.orders o
    where o.customer_id = tests.get_supabase_uid('customer_7')),
  'replay',
  'a repeated webhook for the same payment is a no-op'
);
select is(
  (select public.finalize_paid_booking(o.id, 'cs_second', 'pi_second') from public.orders o
    where o.customer_id = tests.get_supabase_uid('customer_7')),
  'stray',
  'a second, different payment for an already-booked order is a stray payment (refunded)'
);
select is(
  public.finalize_paid_booking(gen_random_uuid(), 'cs_x', 'pi_x'),
  'stray',
  'a payment for an order that does not exist is a stray payment (refunded)'
);

-- customer_8 and customer_9 are being prepared by the kitchen.
update public.reservations set status = 'preparing_order'
where customer_id in (tests.get_supabase_uid('customer_8'), tests.get_supabase_uid('customer_9'));

-- === Refund policy in cancel_reservation() ===
select tests.authenticate_as('customer_7');
select lives_ok(
  $$select public.cancel_reservation((select id from public.reservations where customer_id = tests.get_supabase_uid('customer_7')))$$,
  'customer_7 cancels while the reservation is confirmed'
);
select tests.authenticate_as('customer_8');
select lives_ok(
  $$select public.cancel_reservation((select id from public.reservations where customer_id = tests.get_supabase_uid('customer_8')))$$,
  'customer_8 cancels during preparation'
);
select tests.authenticate_as('owner_h');
select lives_ok(
  $$select public.cancel_reservation((select id from public.reservations where customer_id = tests.get_supabase_uid('customer_9')))$$,
  'owner_h cancels customer_9''s reservation during preparation'
);

select tests.authenticate_as_service_role();
select is(
  (select payment_status from public.orders where customer_id = tests.get_supabase_uid('customer_7')),
  'refund_pending',
  'a customer cancelling while confirmed queues a refund'
);
select is(
  (select payment_status from public.orders where customer_id = tests.get_supabase_uid('customer_8')),
  'paid',
  'a customer cancelling during preparation keeps the payment (no refund)'
);
select is(
  (select payment_status from public.orders where customer_id = tests.get_supabase_uid('customer_9')),
  'refund_pending',
  'the owner cancelling always queues a refund, even during preparation'
);

-- === Privileges ===
select tests.authenticate_as('customer_7');
select throws_ok(
  $$select public.finalize_paid_booking(gen_random_uuid(), 'cs_x', 'pi_x')$$,
  '42501',
  null,
  'an authenticated user cannot call finalize_paid_booking'
);
select throws_ok(
  $$select public.set_order_pending_booking(gen_random_uuid(), 'cs_x', '{}'::jsonb, 1)$$,
  '42501',
  null,
  'an authenticated user cannot call set_order_pending_booking'
);
select throws_ok(
  $$select public.mark_order_refunded(gen_random_uuid())$$,
  '42501',
  null,
  'an authenticated user cannot call mark_order_refunded'
);
-- Whether this errors or silently touches no rows depends on the environment:
-- authenticated has no UPDATE grant on orders in the hosted project, but the
-- local test database's default privileges grant it, leaving RLS (no update
-- policy at all) to filter every row. Either way nothing may change, so the
-- assertion is on the outcome, not on the symptom.
do $
begin
  update public.orders set payment_status = 'paid' where reservation_id is not null;
exception
  when insufficient_privilege then
    null;
end $;
select tests.authenticate_as_service_role();
select is(
  (select count(*)::integer from public.orders where payment_status = 'paid' and restaurant_id = (select id from public.restaurants where name = 'Pay Kapacitet')),
  1,
  'an authenticated user cannot write payment_status (only customer_8''s order is paid)'
);
select tests.authenticate_as('customer_7');

-- === A pending refund blocks deleting the account / restaurant that could retry it ===
-- customer_7 still has a refund_pending order; owner_h's restaurant has two.
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
  $$select public.finalize_paid_booking(gen_random_uuid(), 'cs_x', 'pi_x')$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot call finalize_paid_booking'
);

-- === The refund completing ===
select tests.authenticate_as_service_role();
select lives_ok(
  $$select public.mark_order_refunded((select id from public.orders where customer_id = tests.get_supabase_uid('customer_9')))$$,
  'mark_order_refunded runs for a refund_pending order'
);
select is(
  (select payment_status from public.orders where customer_id = tests.get_supabase_uid('customer_9')),
  'refunded',
  'the order is refunded'
);

select * from finish();
rollback;
