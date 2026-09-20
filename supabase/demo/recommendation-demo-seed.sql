-- Demo data for the recommendation algorithm. NOT a migration and not run by
-- `supabase db reset` (it isn't in config.toml's seed paths): run it by hand
-- against a dev database whenever the demo needs a clean start:
--
--   npx supabase db query --linked -f supabase/demo/recommendation-demo-seed.sql
--
-- It is idempotent - it removes what an earlier run created, then recreates it
-- with timestamps relative to *now*, so re-running also refreshes the recency
-- (an event "3 days ago" is 3 days ago again).
--
-- The scenario is small enough to write on a slide: 5 customers, 6 restaurants,
-- two taste groups that do not overlap.
--
--   Asian group:  Sakura Sushi, Tokyo Ramen, Osaka Izakaya
--   Grill group:  Gaucho Steakhouse, Parrilla Grill, Bife Bar
--
--   customer   what they did (days ago in brackets)
--   Ana        booked Sakura (10) and Tokyo (25), favorited Sakura, viewed Osaka twice (5)
--   Boris      booked Sakura (6) and Osaka (3), viewed Tokyo once (4)
--   Cvijeta    booked Tokyo (14) and Osaka (2), favorited Osaka
--   Dejan      booked Gaucho (8) and Parrilla (20), favorited Gaucho
--   Emilija    booked Gaucho (4) and Bife Bar (1), viewed Parrilla three times (2)
--
-- The seed customers have no password, so nobody can sign in as them; the
-- algorithm only reads what they did. Everything is recognisable by its e-mail
-- (demo.*@seed.local) and by the fixed ids below. The last step also clears the
-- favorites and page views of the shared test customer
-- (test.customer.rr@gmail.com), so a demo run starts from a customer with no
-- history - delete that block if that account's signals should be kept.
-- Reservations at these restaurants (the test customer's included) go with the
-- restaurants when the script re-runs; its bookings elsewhere are not touched.

do $$
declare
  v_owner    constant uuid := 'de000000-0000-4000-8000-000000000000';
  v_ana      constant uuid := 'de000000-0000-4000-8000-000000000001';
  v_boris    constant uuid := 'de000000-0000-4000-8000-000000000002';
  v_cvijeta  constant uuid := 'de000000-0000-4000-8000-000000000003';
  v_dejan    constant uuid := 'de000000-0000-4000-8000-000000000004';
  v_emilija  constant uuid := 'de000000-0000-4000-8000-000000000005';
  v_sakura   constant uuid := 'de000000-0000-4000-8000-0000000000a1';
  v_tokyo    constant uuid := 'de000000-0000-4000-8000-0000000000a2';
  v_osaka    constant uuid := 'de000000-0000-4000-8000-0000000000a3';
  v_gaucho   constant uuid := 'de000000-0000-4000-8000-0000000000a4';
  v_parrilla constant uuid := 'de000000-0000-4000-8000-0000000000a5';
  v_bife     constant uuid := 'de000000-0000-4000-8000-0000000000a6';
begin
  -- === Clean slate: what an earlier run created ===
  -- Orders first: orders.reservation_id is RESTRICT, so a customer's order at a
  -- demo restaurant would otherwise block the restaurant's cascade.
  delete from public.orders
    where restaurant_id in (select id from public.restaurants where owner_id = v_owner);
  delete from public.restaurants where owner_id = v_owner;
  delete from auth.users where email like 'demo.%@seed.local';

  -- Restaurant names are unique among live restaurants, so a real restaurant
  -- that already uses one of these names would abort the inserts below with a
  -- bare unique violation: say so plainly instead, before anything is created.
  if exists (
    select 1 from public.restaurants r
    where r.archived_at is null
      and public.normalize_restaurant_name(r.name) in (
        select public.normalize_restaurant_name(n)
        from unnest(array['Sakura Sushi', 'Tokyo Ramen', 'Osaka Izakaya', 'Gaucho Steakhouse', 'Parrilla Grill', 'Bife Bar']) as n
      )
  ) then
    raise exception 'A live restaurant already uses the name of a demo restaurant (Sakura Sushi, Tokyo Ramen, Osaka Izakaya, Gaucho Steakhouse, Parrilla Grill or Bife Bar) - rename or archive it first.';
  end if;

  -- === Accounts (no password: not loggable) ===
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, created_at, updated_at) values
    (v_owner,   'demo.owner@seed.local',    '{"first_name":"Demo","last_name":"Vlasnik","phone":"+381601110000","role":"owner"}'::jsonb,    '{}'::jsonb, now(), now()),
    (v_ana,     'demo.ana@seed.local',      '{"first_name":"Ana","last_name":"Demo","phone":"+381601110001","role":"customer"}'::jsonb,     '{}'::jsonb, now(), now()),
    (v_boris,   'demo.boris@seed.local',    '{"first_name":"Boris","last_name":"Demo","phone":"+381601110002","role":"customer"}'::jsonb,   '{}'::jsonb, now(), now()),
    (v_cvijeta, 'demo.cvijeta@seed.local',  '{"first_name":"Cvijeta","last_name":"Demo","phone":"+381601110003","role":"customer"}'::jsonb, '{}'::jsonb, now(), now()),
    (v_dejan,   'demo.dejan@seed.local',    '{"first_name":"Dejan","last_name":"Demo","phone":"+381601110004","role":"customer"}'::jsonb,   '{}'::jsonb, now(), now()),
    (v_emilija, 'demo.emilija@seed.local',  '{"first_name":"Emilija","last_name":"Demo","phone":"+381601110005","role":"customer"}'::jsonb, '{}'::jsonb, now(), now());

  -- === Restaurants, open all week with room for a real booking ===
  insert into public.restaurants (id, owner_id, name, capacity) values
    (v_sakura,   v_owner, 'Sakura Sushi',      30),
    (v_tokyo,    v_owner, 'Tokyo Ramen',       30),
    (v_osaka,    v_owner, 'Osaka Izakaya',     30),
    (v_gaucho,   v_owner, 'Gaucho Steakhouse', 30),
    (v_parrilla, v_owner, 'Parrilla Grill',    30),
    (v_bife,     v_owner, 'Bife Bar',          30);

  insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
    select r.id, d, 0, 1440
    from public.restaurants r, generate_series(0, 6) as d
    where r.owner_id = v_owner;

  -- === Bookings (all completed, party of 2, 90 minutes, days ago) ===
  insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
    select b.restaurant_id, b.customer_id, 2,
           now() - b.days_ago * interval '1 day',
           now() - b.days_ago * interval '1 day' + interval '90 minutes',
           'completed'
    from (values
      (v_sakura,   v_ana,      10),
      (v_tokyo,    v_ana,      25),
      (v_sakura,   v_boris,     6),
      (v_osaka,    v_boris,     3),
      (v_tokyo,    v_cvijeta,  14),
      (v_osaka,    v_cvijeta,   2),
      (v_gaucho,   v_dejan,     8),
      (v_parrilla, v_dejan,    20),
      (v_gaucho,   v_emilija,   4),
      (v_bife,     v_emilija,   1)
    ) as b(restaurant_id, customer_id, days_ago);

  -- === Favorites ===
  insert into public.favorites (user_id, restaurant_id, created_at) values
    (v_ana,     v_sakura, now() - interval '9 days'),
    (v_cvijeta, v_osaka,  now() - interval '2 days'),
    (v_dejan,   v_gaucho, now() - interval '7 days');

  -- === Page views ===
  insert into public.restaurant_views (user_id, restaurant_id, view_count, last_viewed_at) values
    (v_ana,     v_osaka,    2, now() - interval '5 days'),
    (v_boris,   v_tokyo,    1, now() - interval '4 days'),
    (v_emilija, v_parrilla, 3, now() - interval '2 days');

  -- === A demo run starts from a customer with no history ===
  delete from public.favorites
    where user_id = (select id from auth.users where email = 'test.customer.rr@gmail.com');
  delete from public.restaurant_views
    where user_id = (select id from auth.users where email = 'test.customer.rr@gmail.com');
end;
$$;
