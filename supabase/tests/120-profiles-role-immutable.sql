-- profiles.role is the authorization source for every RLS policy and RPC, so a
-- user must not be able to rewrite it (see
-- supabase/migrations/20260919140000_profiles_role_immutable.sql). Regression
-- test: before that migration, a table-wide `update` grant let any signed-in
-- user promote themselves to any role.
begin;
select plan(5);

select tests.create_supabase_user('customer_a', 'customera@test.com', null,
  '{"first_name":"Cust","last_name":"A","phone":"555-0101","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_b', 'customerb@test.com', null,
  '{"first_name":"Cust","last_name":"B","phone":"555-0102","role":"customer"}'::jsonb);

select tests.authenticate_as('customer_a');

select throws_ok(
  $$update public.profiles set role = 'owner' where id = tests.get_supabase_uid('customer_a')$$,
  '42501',
  null,
  'a user cannot change their own role'
);

-- The rejected update above must not have changed anything.
select results_eq(
  $$select role from public.profiles where id = tests.get_supabase_uid('customer_a')$$,
  ARRAY['customer'::text],
  'the role is still customer after the rejected update'
);

-- ...and so a self-promoted "owner" still can't create a restaurant.
select throws_ok(
  $$insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('customer_a'), 'Sneaky')$$,
  '42501',
  null,
  'a customer account cannot create a restaurant'
);

-- The fields that are the user's own to edit still work.
select lives_ok(
  $$update public.profiles set first_name = 'Renamed' where id = tests.get_supabase_uid('customer_a')$$,
  'a user can still update their own first name'
);

-- Another user's profile stays out of reach (own-row policy, unchanged).
select results_eq(
  $$update public.profiles set first_name = 'Hijacked'
    where id = tests.get_supabase_uid('customer_b') returning 1$$,
  ARRAY[]::integer[],
  'a user cannot update someone else''s profile'
);

select * from finish();
rollback;
