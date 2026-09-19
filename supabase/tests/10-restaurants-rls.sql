-- RLS coverage for public.restaurants (see supabase/migrations/20260831075904_create_restaurants.sql
-- and .../20260831120000_restaurants_public_select.sql for the policies under test,
-- and .../20260919150000_restaurant_location.sql for the location columns).
begin;
select plan(17);

select tests.rls_enabled('public', 'restaurants');

select tests.create_supabase_user('owner_a', 'ownera@test.com', null,
  '{"first_name":"Owner","last_name":"A","phone":"555-0001","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_b', 'ownerb@test.com', null,
  '{"first_name":"Owner","last_name":"B","phone":"555-0002","role":"owner"}'::jsonb);
select tests.create_supabase_user('employee_a', 'employeea@test.com', null,
  '{"first_name":"Employee","last_name":"A","phone":"555-0003","role":"employee"}'::jsonb);
select tests.create_supabase_user('customer_a', 'customera@test.com', null,
  '{"first_name":"Customer","last_name":"A","phone":"555-0004","role":"customer"}'::jsonb);

-- Owner-role accounts can create a restaurant they own.
select tests.authenticate_as('owner_a');
select lives_ok(
  $$insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_a'), 'A''s Bistro')$$,
  'owner_a can create a restaurant they own'
);

select tests.authenticate_as('owner_b');
select lives_ok(
  $$insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_b'), 'B''s Diner')$$,
  'owner_b can create a restaurant they own'
);

-- default_stay_minutes must be within create_reservation()'s own 30-180
-- minute duration bound (see .../20260908170000_restaurants_default_stay_minutes_bounds.sql) -
-- it's the fallback used whenever a customer leaves a reservation's
-- duration unspecified, so an out-of-range default would make that
-- fallback permanently rejected.
select tests.authenticate_as('owner_a');
select throws_ok(
  $$update public.restaurants set default_stay_minutes = 200 where name = 'A''s Bistro'$$,
  '23514',
  null,
  'default_stay_minutes above 180 is rejected'
);

-- Non-owner-role accounts cannot create a restaurant at all.
select tests.authenticate_as('employee_a');
select throws_ok(
  $$insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('employee_a'), 'Employee Attempt')$$,
  '42501',
  null,
  'employee-role account cannot create a restaurant'
);

select tests.authenticate_as('customer_a');
select throws_ok(
  $$insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('customer_a'), 'Customer Attempt')$$,
  '42501',
  null,
  'customer-role account cannot create a restaurant'
);

-- An owner cannot spoof another owner as the record's owner_id.
select tests.authenticate_as('owner_a');
select throws_ok(
  $$insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_b'), 'Spoofed Restaurant')$$,
  '42501',
  null,
  'owner_a cannot create a restaurant owned by owner_b'
);

-- Owner B cannot update Owner A's restaurant.
select tests.authenticate_as('owner_b');
select results_eq(
  $$update public.restaurants set name = 'Hacked' where name = 'A''s Bistro' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot update owner_a''s restaurant'
);

-- Owner A can update their own restaurant.
select tests.authenticate_as('owner_a');
select results_eq(
  $$update public.restaurants set name = 'A''s Bistro & Grill' where name = 'A''s Bistro' returning 1$$,
  ARRAY[1],
  'owner_a can update their own restaurant'
);

-- Location (address + coordinates for the customer map): an owner can set it
-- on their own restaurant, the coordinates must be a complete, real pair,
-- another owner can't move the pin, and any role can read it back.
select tests.authenticate_as('owner_a');
select lives_ok(
  $$update public.restaurants set address = 'Knez Mihailova 1, Beograd', latitude = 44.8206, longitude = 20.4573 where name = 'A''s Bistro & Grill'$$,
  'owner_a can set the location on their own restaurant'
);

select throws_ok(
  $$update public.restaurants set latitude = 44.8, longitude = null where name = 'A''s Bistro & Grill'$$,
  '23514',
  null,
  'latitude without longitude is rejected'
);

select throws_ok(
  $$update public.restaurants set latitude = 91, longitude = 20 where name = 'A''s Bistro & Grill'$$,
  '23514',
  null,
  'latitude outside -90..90 is rejected'
);

select throws_ok(
  $$update public.restaurants set address = '   ' where name = 'A''s Bistro & Grill'$$,
  '23514',
  null,
  'a blank address is rejected'
);

select tests.authenticate_as('owner_b');
select results_eq(
  $$update public.restaurants set latitude = 0, longitude = 0 where name = 'A''s Bistro & Grill' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot move owner_a''s pin'
);

select tests.authenticate_as('customer_a');
select results_eq(
  $$select latitude from public.restaurants where name = 'A''s Bistro & Grill'$$,
  ARRAY[44.8206::double precision],
  'a customer can read a restaurant''s coordinates'
);

-- Nobody can delete a restaurant with a plain delete any more: it cascades
-- to reservations and orders, so deleting goes through delete_restaurant()
-- (see 140-delete-restaurant.sql), which archives one that has history.
select tests.authenticate_as('owner_b');
select throws_ok(
  $$delete from public.restaurants where name = 'A''s Bistro & Grill'$$,
  '42501',
  null,
  'owner_b cannot delete owner_a''s restaurant'
);

select tests.authenticate_as('owner_a');
select throws_ok(
  $$delete from public.restaurants where name = 'A''s Bistro & Grill'$$,
  '42501',
  null,
  'owner_a cannot delete their own restaurant with a plain delete either'
);

select * from finish();
rollback;
