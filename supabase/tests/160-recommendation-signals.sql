-- Coverage for supabase/migrations/20260920100000_recommendation_signals.sql:
-- the `favorites` and `restaurant_views` tables (RLS, grants, the archived-
-- restaurant guard), record_restaurant_view(), and the two cascades that clean
-- them up (a deleted restaurant, a deleted account).
--
-- owner_r owns Signal Jedan and Signal Dva (both live) and Signal Arhiva
-- (archived directly, since only the archived flag matters here).
-- customer_r1 and customer_r2 are the two customers whose signals must stay
-- separate; employee_r is a non-customer who must be refused.
begin;
select plan(44);

select tests.create_supabase_user('owner_r', 'ownerr@test.com', null,
  '{"first_name":"Owner","last_name":"R","phone":"555-0051","role":"owner"}'::jsonb);
select tests.create_supabase_user('employee_r', 'employeer@test.com', null,
  '{"first_name":"Emp","last_name":"R","phone":"555-0052","role":"employee"}'::jsonb);
select tests.create_supabase_user('customer_r1', 'customerr1@test.com', null,
  '{"first_name":"Cust","last_name":"R1","phone":"555-0053","role":"customer"}'::jsonb);
select tests.create_supabase_user('customer_r2', 'customerr2@test.com', null,
  '{"first_name":"Cust","last_name":"R2","phone":"555-0054","role":"customer"}'::jsonb);

-- === Setup ===
select tests.authenticate_as('owner_r');
insert into public.restaurants (owner_id, name)
  values (tests.get_supabase_uid('owner_r'), 'Signal Jedan'),
         (tests.get_supabase_uid('owner_r'), 'Signal Dva'),
         (tests.get_supabase_uid('owner_r'), 'Signal Arhiva');

reset role;  -- fixture step as the superuser: works whether or not service_role has table grants
update public.restaurants set archived_at = now() where name = 'Signal Arhiva';
select set_config('tests.jedan_id', (select id::text from public.restaurants where name = 'Signal Jedan'), true);
select set_config('tests.dva_id', (select id::text from public.restaurants where name = 'Signal Dva'), true);
select set_config('tests.arhiva_id', (select id::text from public.restaurants where name = 'Signal Arhiva'), true);
select set_config('tests.c1', tests.get_supabase_uid('customer_r1')::text, true);
select set_config('tests.c2', tests.get_supabase_uid('customer_r2')::text, true);

-- === Permissions: signed-out callers get nothing ===
select tests.clear_authentication();
select throws_ok(
  $$select public.record_restaurant_view(current_setting('tests.jedan_id')::uuid)$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot execute record_restaurant_view'
);
select throws_ok(
  $$select count(*) from public.favorites$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot read favorites'
);
select throws_ok(
  $$select count(*) from public.restaurant_views$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot read restaurant_views'
);

-- === favorites: a customer's own toggle ===
select tests.authenticate_as('customer_r1');
select lives_ok(
  $$insert into public.favorites (user_id, restaurant_id)
    values (current_setting('tests.c1')::uuid, current_setting('tests.jedan_id')::uuid)$$,
  'a customer can favorite a restaurant'
);
select throws_ok(
  $$insert into public.favorites (user_id, restaurant_id)
    values (current_setting('tests.c1')::uuid, current_setting('tests.jedan_id')::uuid)$$,
  '23505',
  null,
  'favoriting the same restaurant twice is a duplicate, not a second row'
);
select throws_ok(
  $$insert into public.favorites (user_id, restaurant_id)
    values (current_setting('tests.c2')::uuid, current_setting('tests.jedan_id')::uuid)$$,
  '42501',
  null,
  'a customer cannot add a favorite in someone else''s name'
);
select throws_ok(
  $$insert into public.favorites (user_id, restaurant_id)
    values (current_setting('tests.c1')::uuid, current_setting('tests.arhiva_id')::uuid)$$,
  'P0001',
  'Restoran ne postoji.',
  'an archived restaurant cannot be favorited'
);
select throws_ok(
  $$insert into public.favorites (user_id, restaurant_id)
    values (current_setting('tests.c1')::uuid, '00000000-0000-0000-0000-000000000000')$$,
  '23503',
  null,
  'a restaurant that does not exist cannot be favorited'
);
select is(
  (select count(*) from public.favorites),
  1::bigint,
  'the customer sees exactly their own favorite'
);
select throws_ok(
  $$update public.favorites set created_at = now()$$,
  '42501',
  null,
  'a favorite has no editable column: there is no update grant'
);

-- Another customer neither sees it nor can remove it.
select tests.authenticate_as('customer_r2');
select is(
  (select count(*) from public.favorites),
  0::bigint,
  'another customer does not see it'
);
select lives_ok(
  $$delete from public.favorites where restaurant_id = current_setting('tests.jedan_id')::uuid$$,
  'another customer''s delete runs but matches nothing'
);
select tests.authenticate_as('customer_r1');
select is(
  (select count(*) from public.favorites),
  1::bigint,
  'so the favorite is still there'
);

-- Owners and employees are not customers: no favorites, and they see none.
select tests.authenticate_as('owner_r');
select throws_ok(
  $$insert into public.favorites (user_id, restaurant_id)
    values (tests.get_supabase_uid('owner_r'), current_setting('tests.jedan_id')::uuid)$$,
  '42501',
  null,
  'an owner-role account cannot add a favorite'
);
select tests.authenticate_as('employee_r');
select throws_ok(
  $$insert into public.favorites (user_id, restaurant_id)
    values (tests.get_supabase_uid('employee_r'), current_setting('tests.jedan_id')::uuid)$$,
  '42501',
  null,
  'an employee-role account cannot add a favorite'
);
select tests.authenticate_as('owner_r');
select is(
  (select count(*) from public.favorites),
  0::bigint,
  'the restaurant''s owner cannot see who favorited it'
);

-- Removing it works.
select tests.authenticate_as('customer_r1');
select lives_ok(
  $$delete from public.favorites where restaurant_id = current_setting('tests.jedan_id')::uuid$$,
  'a customer can remove their favorite'
);
select is(
  (select count(*) from public.favorites),
  0::bigint,
  'and it is gone'
);

-- === restaurant_views: written only through record_restaurant_view() ===
select lives_ok(
  $$select public.record_restaurant_view(current_setting('tests.jedan_id')::uuid)$$,
  'a customer''s first view is recorded'
);
select results_eq(
  $$select view_count from public.restaurant_views where restaurant_id = current_setting('tests.jedan_id')::uuid$$,
  $$values (1)$$,
  'as a single row with a count of 1'
);
select lives_ok(
  $$select public.record_restaurant_view(current_setting('tests.jedan_id')::uuid)$$,
  'a second view is recorded'
);
select results_eq(
  $$select view_count from public.restaurant_views where restaurant_id = current_setting('tests.jedan_id')::uuid$$,
  $$values (2)$$,
  'by bumping the same row to 2, not adding another'
);
select throws_ok(
  $$insert into public.restaurant_views (user_id, restaurant_id, view_count)
    values (current_setting('tests.c1')::uuid, current_setting('tests.dva_id')::uuid, 50)$$,
  '42501',
  null,
  'a client cannot insert a view row directly (no insert grant)'
);
select throws_ok(
  $$update public.restaurant_views set view_count = 999$$,
  '42501',
  null,
  'a client cannot set its own view count (no update grant)'
);
select throws_ok(
  $$select public.record_restaurant_view(current_setting('tests.arhiva_id')::uuid)$$,
  'P0001',
  'Restoran ne postoji.',
  'an archived restaurant''s page view is refused'
);
select throws_ok(
  $$select public.record_restaurant_view('00000000-0000-0000-0000-000000000000')$$,
  'P0001',
  'Restoran ne postoji.',
  'so is a restaurant that does not exist, with the same message'
);

select tests.authenticate_as('customer_r2');
select is(
  (select count(*) from public.restaurant_views),
  0::bigint,
  'another customer does not see the first customer''s views'
);
select tests.authenticate_as('owner_r');
select throws_ok(
  $$select public.record_restaurant_view(current_setting('tests.jedan_id')::uuid)$$,
  'P0001',
  'Samo nalozi tipa kupac mogu pregledati restorane.',
  'an owner-role account cannot record a view'
);
select is(
  (select count(*) from public.restaurant_views),
  0::bigint,
  'and the restaurant''s owner cannot see who viewed it'
);
select tests.authenticate_as('employee_r');
select throws_ok(
  $$select public.record_restaurant_view(current_setting('tests.jedan_id')::uuid)$$,
  'P0001',
  'Samo nalozi tipa kupac mogu pregledati restorane.',
  'an employee-role account cannot record a view'
);

-- === Cascade: a deleted restaurant takes its signals with it ===
select tests.authenticate_as('customer_r2');
select lives_ok(
  $$insert into public.favorites (user_id, restaurant_id)
    select current_setting('tests.c2')::uuid, id from public.restaurants
    where name in ('Signal Jedan', 'Signal Dva')$$,
  'customer_r2 favorites both live restaurants'
);
select lives_ok(
  $$select public.record_restaurant_view(current_setting('tests.jedan_id')::uuid)$$,
  'customer_r2 views Signal Jedan'
);
select lives_ok(
  $$select public.record_restaurant_view(current_setting('tests.dva_id')::uuid)$$,
  'customer_r2 views Signal Dva'
);

select tests.authenticate_as('customer_r1');
select lives_ok(
  $$insert into public.favorites (user_id, restaurant_id)
    select current_setting('tests.c1')::uuid, id from public.restaurants
    where name in ('Signal Jedan', 'Signal Dva')$$,
  'customer_r1 favorites both live restaurants'
);
select lives_ok(
  $$select public.record_restaurant_view(current_setting('tests.dva_id')::uuid)$$,
  'customer_r1 views Signal Dva'
);

-- Signal Dva has no reservations, so it is really deleted (not archived).
select tests.authenticate_as('owner_r');
select is(
  (select public.delete_restaurant(current_setting('tests.dva_id')::uuid)),
  'deleted',
  'the owner deletes Signal Dva'
);

reset role;
select is(
  (select count(*) from public.favorites where restaurant_id = current_setting('tests.dva_id')::uuid),
  0::bigint,
  'its favorites went with it'
);
select is(
  (select count(*) from public.restaurant_views where restaurant_id = current_setting('tests.dva_id')::uuid),
  0::bigint,
  'and its views'
);
select is(
  (select count(*) from public.favorites where restaurant_id = current_setting('tests.jedan_id')::uuid),
  2::bigint,
  'the other restaurant''s favorites are untouched'
);

-- === Cascade: a deleted account takes its signals with it ===
select tests.authenticate_as('customer_r1');
select lives_ok(
  $$select public.delete_my_account()$$,
  'customer_r1 deletes their account'
);

reset role;
select is(
  (select count(*) from public.favorites where user_id = current_setting('tests.c1')::uuid),
  0::bigint,
  'their favorites are deleted, not left behind anonymized'
);
select is(
  (select count(*) from public.restaurant_views where user_id = current_setting('tests.c1')::uuid),
  0::bigint,
  'so are their views'
);
select is(
  (select count(*) from public.favorites where user_id = current_setting('tests.c2')::uuid),
  1::bigint,
  'customer_r2''s remaining favorite is untouched'
);
select is(
  (select count(*) from public.restaurant_views where user_id = current_setting('tests.c2')::uuid),
  1::bigint,
  'and so is their remaining view'
);

select * from finish();
rollback;
