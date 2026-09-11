-- RLS + start_cart()/add_order_item() + create_reservation(..., p_order_id)
-- coverage (see supabase/migrations/20260911100000_create_orders.sql
-- through .../20260911111500_create_reservation_finalize_order.sql).
--
-- A's Bistro (owner_a) has plain restaurant.capacity (no sections/layout),
-- 24/7 hours, and a small menu: "Pica" (no options), "Salata" (a required
-- single-select "Velicina" group + an optional multi-select "Dodaci"
-- group), "Sarma" (unavailable from the start), and "Pomfrit" (available
-- until deliberately toggled off mid-test to exercise the confirm-time
-- availability re-check). B's Diner (owner_b) exists only to exercise
-- cross-restaurant rejections.
begin;
select plan(49);

select tests.rls_enabled('public', 'orders');
select tests.rls_enabled('public', 'order_items');
select tests.rls_enabled('public', 'order_item_choices');

select tests.create_supabase_user('owner_a', 'ownera@test.com', null,
  '{"first_name":"Owner","last_name":"A","phone":"555-0001","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_b', 'ownerb@test.com', null,
  '{"first_name":"Owner","last_name":"B","phone":"555-0002","role":"owner"}'::jsonb);
select tests.create_supabase_user('customer_1', 'customer1@test.com', null,
  '{"first_name":"Cust","last_name":"One","phone":"555-0003","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_2', 'customer2@test.com', null,
  '{"first_name":"Cust","last_name":"Two","phone":"555-0004","role":"customer"}'::jsonb);
select tests.create_supabase_user('employee_1', 'employee1@test.com', null,
  '{"first_name":"Emp","last_name":"One","phone":"555-0005","role":"employee"}'::jsonb);
select tests.create_supabase_user('employee_2', 'employee2@test.com', null,
  '{"first_name":"Emp","last_name":"Two","phone":"555-0006","role":"employee"}'::jsonb);

-- Setup (not asserted): A's Bistro - plain capacity, 24/7 hours, menu.
select tests.authenticate_as('owner_a');
insert into public.restaurants (owner_id, name, capacity) values (tests.get_supabase_uid('owner_a'), 'A''s Bistro', 50);
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'A''s Bistro'), d, 0, 1440
  from generate_series(0, 6) as d;
insert into public.menu_categories (restaurant_id, name)
  values ((select id from public.restaurants where name = 'A''s Bistro'), 'Jela');
insert into public.menu_items (restaurant_id, category_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'A''s Bistro'),
    (select id from public.menu_categories where name = 'Jela'), 'Pica', 500, true);
insert into public.menu_items (restaurant_id, category_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'A''s Bistro'),
    (select id from public.menu_categories where name = 'Jela'), 'Salata', 300, true);
insert into public.menu_items (restaurant_id, category_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'A''s Bistro'),
    (select id from public.menu_categories where name = 'Jela'), 'Sarma', 400, false);
insert into public.menu_items (restaurant_id, category_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'A''s Bistro'),
    (select id from public.menu_categories where name = 'Jela'), 'Pomfrit', 200, true);
insert into public.menu_item_options (menu_item_id, name, is_required, allow_multiple)
  values ((select id from public.menu_items where name = 'Salata'), 'Velicina', true, false);
insert into public.menu_item_options (menu_item_id, name, is_required, allow_multiple)
  values ((select id from public.menu_items where name = 'Salata'), 'Dodaci', false, true);
insert into public.menu_item_option_choices (option_id, name, price_delta)
  values ((select id from public.menu_item_options where name = 'Velicina'), 'Mala', 0);
insert into public.menu_item_option_choices (option_id, name, price_delta)
  values ((select id from public.menu_item_options where name = 'Velicina'), 'Velika', 150);
insert into public.menu_item_option_choices (option_id, name, price_delta)
  values ((select id from public.menu_item_options where name = 'Dodaci'), 'Krutoni', 50);

select tests.authenticate_as('employee_1');
insert into public.restaurant_staff (restaurant_id, employee_id)
  values ((select id from public.restaurants where name = 'A''s Bistro'), tests.get_supabase_uid('employee_1'));
select tests.authenticate_as('employee_2');
insert into public.restaurant_staff (restaurant_id, employee_id)
  values ((select id from public.restaurants where name = 'A''s Bistro'), tests.get_supabase_uid('employee_2'));
select tests.authenticate_as('owner_a');
update public.restaurant_staff set status = 'accepted'
  where restaurant_id = (select id from public.restaurants where name = 'A''s Bistro')
    and employee_id = tests.get_supabase_uid('employee_1');

-- Setup (not asserted): B's Diner - unrelated restaurant/menu item, used
-- only for cross-restaurant rejections.
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_b'), 'B''s Diner');
insert into public.menu_items (restaurant_id, name, price, is_available)
  values ((select id from public.restaurants where name = 'B''s Diner'), 'Tuđe jelo', 100, true);

-- === Cart building: start_cart() / add_order_item() ===
select tests.authenticate_as('customer_1');
select lives_ok(
  $$select public.start_cart((select id from public.restaurants where name = 'A''s Bistro'))$$,
  'customer_1 can start a cart at A''s Bistro'
);

select results_eq(
  $$select status, restaurant_id from public.orders where customer_id = tests.get_supabase_uid('customer_1')$$,
  $$select 'draft', (select id from public.restaurants where name = 'A''s Bistro')$$,
  'the new cart is a draft scoped to A''s Bistro'
);

select results_eq(
  $$select public.start_cart((select id from public.restaurants where name = 'A''s Bistro'))$$,
  $$select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')$$,
  'calling start_cart again for the same restaurant returns the same draft, not a new one'
);

select throws_ok(
  $$insert into public.orders (restaurant_id, customer_id)
    values ((select id from public.restaurants where name = 'A''s Bistro'), tests.get_supabase_uid('customer_1'))$$,
  '42501',
  null,
  'direct insert into orders bypassing start_cart() is rejected'
);

select lives_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')),
      (select id from public.menu_items where name = 'Pica'),
      '{}', 2
    )$$,
  'customer_1 can add a plain (no-options) item to their cart'
);

select results_eq(
  $$select unit_price, quantity from public.order_items
    where order_id = (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1'))
      and item_name = 'Pica'$$,
  $$select 500.00, 2$$,
  'the Pica line snapshots the item''s base price with no modifiers'
);

select lives_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')),
      (select id from public.menu_items where name = 'Salata'),
      array[
        (select id from public.menu_item_option_choices where name = 'Velika'),
        (select id from public.menu_item_option_choices where name = 'Krutoni')
      ],
      1
    )$$,
  'customer_1 can add an item with a required choice and an optional choice'
);

select results_eq(
  $$select unit_price from public.order_items
    where order_id = (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1'))
      and item_name = 'Salata'$$,
  ARRAY[500.00],
  'the Salata line''s price is the base price plus both chosen deltas (300 + 150 + 50)'
);

select results_eq(
  $$select choice_name from public.order_item_choices oic
    join public.order_items oi on oi.id = oic.order_item_id
    where oi.item_name = 'Salata' order by choice_name$$,
  ARRAY['Krutoni', 'Velika'],
  'both chosen choices were snapshotted onto the Salata line'
);

select throws_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')),
      (select id from public.menu_items where name = 'Salata'),
      '{}', 1
    )$$,
  'P0001',
  'Grupa opcija "Velicina" je obavezna.',
  'adding Salata with no choices at all is rejected - Velicina is required'
);

select throws_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')),
      (select id from public.menu_items where name = 'Salata'),
      array[
        (select id from public.menu_item_option_choices where name = 'Mala'),
        (select id from public.menu_item_option_choices where name = 'Velika')
      ],
      1
    )$$,
  'P0001',
  'Grupa opcija "Velicina" dozvoljava samo jedan izbor.',
  'picking two choices from the single-select Velicina group is rejected'
);

select throws_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')),
      (select id from public.menu_items where name = 'Salata'),
      array[
        (select id from public.menu_item_option_choices where name = 'Velika'),
        (select id from public.menu_item_option_choices where name = 'Velika')
      ],
      1
    )$$,
  'P0001',
  'Isti izbor je naveden više puta.',
  'the same choice id listed twice is rejected'
);

select throws_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')),
      (select id from public.menu_items where name = 'Pica'),
      array[(select id from public.menu_item_option_choices where name = 'Velika')],
      1
    )$$,
  'P0001',
  'Izabrana opcija ne pripada ovoj stavci.',
  'a choice that belongs to a different item is rejected'
);

select throws_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')),
      (select id from public.menu_items where name = 'Tuđe jelo'),
      '{}', 1
    )$$,
  'P0001',
  'Stavka ne postoji u ovom restoranu.',
  'a menu item from a different restaurant than the cart''s own is rejected'
);

select throws_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')),
      (select id from public.menu_items where name = 'Sarma'),
      '{}', 1
    )$$,
  'P0001',
  'Stavka trenutno nije dostupna.',
  'an unavailable item cannot be added to the cart'
);

select tests.authenticate_as('customer_2');
select throws_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')),
      (select id from public.menu_items where name = 'Pica'),
      '{}', 1
    )$$,
  'P0001',
  'Korpa ne postoji.',
  'customer_2 cannot add an item to customer_1''s cart'
);

select throws_ok(
  $$insert into public.order_items (order_id, menu_item_id, item_name, unit_price, quantity)
    values (
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1')),
      (select id from public.menu_items where name = 'Pica'), 'Pica', 1, 1
    )$$,
  '42501',
  null,
  'direct insert into order_items bypassing add_order_item() is rejected'
);

select tests.authenticate_as('customer_1');
select lives_ok(
  $$update public.order_items set quantity = 3
    where order_id = (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1'))
      and item_name = 'Pica'$$,
  'customer_1 can update the quantity on their own draft line'
);

select results_eq(
  $$select quantity from public.order_items
    where order_id = (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1'))
      and item_name = 'Pica'$$,
  ARRAY[3],
  'the quantity update took effect'
);

select throws_ok(
  $$update public.order_items set unit_price = 1
    where order_id = (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1'))
      and item_name = 'Pica'$$,
  '42501',
  null,
  'the column-level grant only covers quantity - a direct unit_price update is rejected'
);

select lives_ok(
  $$delete from public.order_items
    where order_id = (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1'))
      and item_name = 'Pica'$$,
  'customer_1 can remove a line from their own draft cart'
);

select results_eq(
  $$select count(*)::int from public.order_items
    where order_id = (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1'))$$,
  ARRAY[1],
  'only the Salata line remains after removing Pica'
);

-- Drafts are private: nobody but the owning customer can see them.
select tests.authenticate_as('customer_2');
select results_eq(
  $$select count(*)::int from public.orders where customer_id = tests.get_supabase_uid('customer_1')$$,
  ARRAY[0],
  'customer_2 cannot see customer_1''s draft order'
);

select tests.authenticate_as('owner_a');
select results_eq(
  $$select count(*)::int from public.orders where customer_id = tests.get_supabase_uid('customer_1')$$,
  ARRAY[0],
  'the restaurant''s own owner cannot see a still-draft order'
);

select tests.authenticate_as('employee_1');
select results_eq(
  $$select count(*)::int from public.orders where customer_id = tests.get_supabase_uid('customer_1')$$,
  ARRAY[0],
  'an accepted staff member cannot see a still-draft order either'
);

-- === create_reservation(..., p_order_id): finalizing the linked order ===
select tests.authenticate_as('customer_1');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '1 day 12 hours'),
      60,
      null,
      null,
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1'))
    )$$,
  'confirming a reservation with a non-empty cart succeeds'
);

select results_eq(
  $$select o.status, (o.reservation_id = r.id)
    from public.orders o
    join public.reservations r on r.customer_id = o.customer_id and r.party_size = 2
      and r.starts_at = (date_trunc('day', now()) + interval '1 day 12 hours')
    where o.customer_id = tests.get_supabase_uid('customer_1')$$,
  $$select 'confirmed', true$$,
  'the linked order was flipped to confirmed and stamped with the new reservation''s id'
);

select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '5 days 12 hours'),
      60,
      null,
      null,
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1'))
    )$$,
  'P0001',
  'Porudžbina je već finalizovana.',
  'reusing an already-confirmed order id is rejected'
);

select lives_ok(
  $$select public.start_cart((select id from public.restaurants where name = 'A''s Bistro'))$$,
  'customer_1 can start a fresh cart now that the previous one is confirmed, not draft'
);

select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '2 days 12 hours'),
      60,
      null,
      null,
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1') and status = 'draft')
    )$$,
  'P0001',
  'Korpa je prazna.',
  'confirming a reservation whose linked cart has no items is rejected'
);

select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'B''s Diner'),
      2,
      (date_trunc('day', now()) + interval '3 days 12 hours'),
      60,
      null,
      null,
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1') and status = 'draft')
    )$$,
  'P0001',
  'Porudžbina pripada drugom restoranu.',
  'p_restaurant_id not matching the order''s own restaurant is rejected'
);

select tests.authenticate_as('customer_2');
select lives_ok(
  $$select public.start_cart((select id from public.restaurants where name = 'A''s Bistro'))$$,
  'customer_2 starts their own cart at A''s Bistro'
);
select lives_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_2')),
      (select id from public.menu_items where name = 'Pica'), '{}', 1
    )$$,
  'customer_2 adds an item to their own cart'
);

select tests.authenticate_as('customer_1');
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '4 days 12 hours'),
      60,
      null,
      null,
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_2'))
    )$$,
  'P0001',
  'Porudžbina ne postoji.',
  'customer_1 cannot confirm a reservation against customer_2''s order'
);

-- customer_1's still-empty A's Bistro draft (from above) gets Pomfrit added,
-- then the owner marks Pomfrit unavailable before the confirm attempt -
-- exercises the confirm-time availability re-check.
select lives_ok(
  $$select public.add_order_item(
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1') and status = 'draft'),
      (select id from public.menu_items where name = 'Pomfrit'), '{}', 1
    )$$,
  'customer_1 adds Pomfrit to their fresh draft'
);

select tests.authenticate_as('owner_a');
update public.menu_items set is_available = false where name = 'Pomfrit';

select tests.authenticate_as('customer_1');
select throws_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'A''s Bistro'),
      2,
      (date_trunc('day', now()) + interval '6 days 12 hours'),
      60,
      null,
      null,
      (select id from public.orders where customer_id = tests.get_supabase_uid('customer_1') and status = 'draft')
    )$$,
  'P0001',
  'Neke stavke iz korpe više nisu dostupne. Vratite se na meni i ažurirajte porudžbinu.',
  'confirming a reservation whose cart contains a now-unavailable item is rejected'
);

select results_eq(
  $$select count(*)::int from public.reservations
    where customer_id = tests.get_supabase_uid('customer_1')
      and starts_at = (date_trunc('day', now()) + interval '6 days 12 hours')$$,
  ARRAY[0],
  'the rejected confirm attempt left no reservation row behind - fully rolled back'
);

select results_eq(
  $$select status from public.orders where customer_id = tests.get_supabase_uid('customer_1') and status = 'draft'$$,
  ARRAY['draft'],
  'and the order itself is still a draft, not partially confirmed'
);

-- === start_cart(): switching restaurants replaces the old draft ===
select lives_ok(
  $$select public.start_cart((select id from public.restaurants where name = 'B''s Diner'))$$,
  'customer_1 can start a cart at a different restaurant'
);

select is_empty(
  $$select 1 from public.orders
    where customer_id = tests.get_supabase_uid('customer_1')
      and restaurant_id = (select id from public.restaurants where name = 'A''s Bistro')
      and status = 'draft'$$,
  'starting a cart at B''s Diner deleted the old A''s Bistro draft (and, by cascade, its Pomfrit line)'
);

select results_eq(
  $$select restaurant_id from public.orders where customer_id = tests.get_supabase_uid('customer_1') and status = 'draft'$$,
  $$select id from public.restaurants where name = 'B''s Diner'$$,
  'the customer''s one draft is now scoped to B''s Diner'
);

-- === Confirmed-order visibility ===
select tests.authenticate_as('owner_a');
select results_eq(
  $$select count(*)::int from public.orders
    where customer_id = tests.get_supabase_uid('customer_1') and status = 'confirmed'$$,
  ARRAY[1],
  'the restaurant''s owner can see the confirmed order'
);

select results_eq(
  $$select count(*)::int from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where o.customer_id = tests.get_supabase_uid('customer_1') and o.status = 'confirmed'$$,
  ARRAY[1],
  'and its items'
);

select tests.authenticate_as('employee_1');
select results_eq(
  $$select count(*)::int from public.orders
    where customer_id = tests.get_supabase_uid('customer_1') and status = 'confirmed'$$,
  ARRAY[1],
  'an accepted staff member can see the confirmed order'
);

select tests.authenticate_as('employee_2');
select results_eq(
  $$select count(*)::int from public.orders
    where customer_id = tests.get_supabase_uid('customer_1') and status = 'confirmed'$$,
  ARRAY[0],
  'a pending (not yet accepted) staff member cannot see it'
);

select tests.authenticate_as('owner_b');
select results_eq(
  $$select count(*)::int from public.orders
    where customer_id = tests.get_supabase_uid('customer_1') and status = 'confirmed'$$,
  ARRAY[0],
  'an unrelated owner cannot see another restaurant''s confirmed order'
);

select * from finish();
rollback;
