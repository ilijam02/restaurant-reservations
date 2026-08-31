-- RLS coverage for public.restaurants (see supabase/migrations/20260831075904_create_restaurants.sql
-- and .../20260831120000_restaurants_public_select.sql for the policies under test).
begin;
select plan(10);

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

-- Owner B cannot delete Owner A's restaurant.
select tests.authenticate_as('owner_b');
select results_eq(
  $$delete from public.restaurants where name = 'A''s Bistro & Grill' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot delete owner_a''s restaurant'
);

-- Owner A can delete their own restaurant.
select tests.authenticate_as('owner_a');
select results_eq(
  $$delete from public.restaurants where name = 'A''s Bistro & Grill' returning 1$$,
  ARRAY[1],
  'owner_a can delete their own restaurant'
);

select * from finish();
rollback;
