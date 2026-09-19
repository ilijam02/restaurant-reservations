-- profiles.role is the authorization source for every RLS policy and RPC, so a
-- user must not be able to rewrite it (see
-- supabase/migrations/20260919140000_profiles_role_immutable.sql). Regression
-- test: before that migration, a table-wide `update` grant let any signed-in
-- user promote themselves to any role.
begin;
select plan(8);

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

-- The realistic attack: smuggle the role change in alongside an allowed field.
-- The whole statement must be rejected, not just the role part.
select throws_ok(
  $$update public.profiles set first_name = 'Sneaky', role = 'owner'
    where id = tests.get_supabase_uid('customer_a')$$,
  '42501',
  null,
  'a mixed update that includes role is rejected'
);

-- Neither rejected update may have changed anything.
select results_eq(
  $$select first_name, role from public.profiles where id = tests.get_supabase_uid('customer_a')$$,
  $$values ('Cust'::text, 'customer'::text)$$,
  'first_name and role are unchanged after the rejected updates'
);

-- Column privileges, checked directly: nothing but the three editable fields.
select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'role', 'UPDATE'),
  'authenticated has no UPDATE privilege on profiles.role'
);

select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'id', 'UPDATE')
    and not has_column_privilege('authenticated', 'public.profiles', 'created_at', 'UPDATE'),
  'authenticated has no UPDATE privilege on profiles.id or profiles.created_at'
);

-- The fields that are the user's own to edit still work - and actually change
-- the row (a policy silently matching nothing would also "succeed").
select results_eq(
  $$update public.profiles set first_name = 'Renamed'
    where id = tests.get_supabase_uid('customer_a') returning 1$$,
  ARRAY[1],
  'a user can update their own first name'
);

select results_eq(
  $$select first_name from public.profiles where id = tests.get_supabase_uid('customer_a')$$,
  ARRAY['Renamed'::text],
  'the first name change was actually saved'
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
