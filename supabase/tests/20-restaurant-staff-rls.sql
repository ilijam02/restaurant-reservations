-- RLS coverage for public.restaurant_staff and the staff-visibility policy it
-- adds to public.profiles (see supabase/migrations/20260831150000_restaurant_staff.sql
-- and .../20260831151500_fix_restaurant_staff_profile_policy_recursion.sql).
--
-- The first assertion below (employee_x's application insert succeeding) is
-- also the regression test for the recursion bug that the second migration
-- fixed: that insert's WITH CHECK queries public.profiles, and profiles'
-- select policy queries restaurant_staff back — before the fix, Postgres
-- detected that as a 42P17 cycle at plan time and the insert failed outright.
begin;
select plan(11);

select tests.rls_enabled('public', 'restaurant_staff');

select tests.create_supabase_user('owner_a', 'ownera@test.com', null,
  '{"first_name":"Owner","last_name":"A","phone":"555-0001","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_b', 'ownerb@test.com', null,
  '{"first_name":"Owner","last_name":"B","phone":"555-0002","role":"owner"}'::jsonb);
select tests.create_supabase_user('employee_x', 'employeex@test.com', null,
  '{"first_name":"Employee","last_name":"X","phone":"555-0009","role":"employee"}'::jsonb);

-- Setup (not asserted): each owner creates their own restaurant.
select tests.authenticate_as('owner_a');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_a'), 'A''s Bistro');

select tests.authenticate_as('owner_b');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_b'), 'B''s Diner');

-- Employee-role accounts can apply (as 'pending') to a restaurant.
select tests.authenticate_as('employee_x');
select lives_ok(
  $$insert into public.restaurant_staff (restaurant_id, employee_id)
    values ((select id from public.restaurants where name = 'A''s Bistro'), tests.get_supabase_uid('employee_x'))$$,
  'employee_x can apply to a restaurant (starts pending)'
);

-- An applicant cannot insert themselves directly as 'accepted'.
select throws_ok(
  $$insert into public.restaurant_staff (restaurant_id, employee_id, status)
    values ((select id from public.restaurants where name = 'B''s Diner'), tests.get_supabase_uid('employee_x'), 'accepted')$$,
  '42501',
  null,
  'employee_x cannot insert their own application as already-accepted'
);

-- An employee cannot accept their own pending application.
select results_eq(
  $$update public.restaurant_staff set status = 'accepted'
    where employee_id = tests.get_supabase_uid('employee_x') returning 1$$,
  ARRAY[]::integer[],
  'employee_x cannot set their own application status to accepted'
);

-- Owner B (not the restaurant's owner) cannot accept employee_x's application at A's Bistro.
select tests.authenticate_as('owner_b');
select results_eq(
  $$update public.restaurant_staff set status = 'accepted'
    where employee_id = tests.get_supabase_uid('employee_x') returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot accept an application to owner_a''s restaurant'
);

-- Owner B cannot see employee_x's profile (no staff relationship at owner_b's restaurant).
select results_eq(
  $$select 1 from public.profiles where id = tests.get_supabase_uid('employee_x')$$,
  ARRAY[]::integer[],
  'owner_b cannot view employee_x''s profile'
);

-- Owner A (the restaurant's actual owner) can accept the application.
select tests.authenticate_as('owner_a');
select results_eq(
  $$update public.restaurant_staff set status = 'accepted'
    where employee_id = tests.get_supabase_uid('employee_x') returning 1$$,
  ARRAY[1],
  'owner_a can accept employee_x''s application to their own restaurant'
);

-- Owner A can now see employee_x's profile.
select results_eq(
  $$select 1 from public.profiles where id = tests.get_supabase_uid('employee_x')$$,
  ARRAY[1],
  'owner_a can view employee_x''s profile once they are staff'
);

-- Once accepted, the employee can no longer self-cancel (that's owner-only removal now).
select tests.authenticate_as('employee_x');
select results_eq(
  $$delete from public.restaurant_staff where employee_id = tests.get_supabase_uid('employee_x') returning 1$$,
  ARRAY[]::integer[],
  'employee_x cannot cancel/remove their own accepted staff row'
);

-- Owner B cannot remove employee_x from owner_a's restaurant.
select tests.authenticate_as('owner_b');
select results_eq(
  $$delete from public.restaurant_staff where employee_id = tests.get_supabase_uid('employee_x') returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot remove staff from owner_a''s restaurant'
);

-- Owner A can remove employee_x from their own restaurant.
select tests.authenticate_as('owner_a');
select results_eq(
  $$delete from public.restaurant_staff where employee_id = tests.get_supabase_uid('employee_x') returning 1$$,
  ARRAY[1],
  'owner_a can remove staff from their own restaurant'
);

select * from finish();
rollback;
