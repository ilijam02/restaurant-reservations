-- Coverage for supabase/migrations/20260920120000_recommendation_scoring.sql:
-- the collaborative-KNN scoring behind recommend_restaurants(), the popularity
-- fallback, the blend, recency, the two parameter profiles, and who is allowed
-- to call what.
--
-- Everything time-dependent is evaluated at a fixed instant (tests.as_of), and
-- every event is placed relative to it, so the numbers below don't drift.
-- Expected values for the base scenario were cross-checked against an
-- independent implementation of the algorithm (written from the design, not
-- from the SQL) before being pinned here.
--
-- Base scenario (days before as_of in brackets), two taste groups:
--   ana      booked Sakura (10) and Tokyo (25); favorited Sakura (9); viewed Osaka twice (5)
--   boris    booked Sakura (6) and Osaka (3); viewed Tokyo once (4)
--   cvijeta  booked Tokyo (14) and Osaka (2); favorited Osaka (2)
--   dejan    booked Gaucho (8) and Parrilla (20); favorited Gaucho (7)
--   emilija  booked Gaucho (4) and Bife (1); viewed Parrilla three times (2)
--   cold     has no history at all
-- Then, for the edge cases, viewer / booker / loner / hub / edge join in, and
-- `live` (events relative to the real now(), for the tests of the public wrapper) and
-- victim / real1 / real2 / sy1..sy6 (an isolated throwaway-account attack, below).
begin;
select plan(58);

select tests.create_supabase_user('owner_u', 'owneru@test.com', null,
  '{"first_name":"Owner","last_name":"U","phone":"555-0071","role":"owner"}'::jsonb);
select tests.create_supabase_user('ana', 'ana@test.com', null,
  '{"first_name":"Ana","last_name":"A","phone":"555-0072","role":"customer"}'::jsonb);
select tests.create_supabase_user('boris', 'boris@test.com', null,
  '{"first_name":"Boris","last_name":"B","phone":"555-0073","role":"customer"}'::jsonb);
select tests.create_supabase_user('cvijeta', 'cvijeta@test.com', null,
  '{"first_name":"Cvijeta","last_name":"C","phone":"555-0074","role":"customer"}'::jsonb);
select tests.create_supabase_user('dejan', 'dejan@test.com', null,
  '{"first_name":"Dejan","last_name":"D","phone":"555-0075","role":"customer"}'::jsonb);
select tests.create_supabase_user('emilija', 'emilija@test.com', null,
  '{"first_name":"Emilija","last_name":"E","phone":"555-0076","role":"customer"}'::jsonb);
select tests.create_supabase_user('cold', 'cold@test.com', null,
  '{"first_name":"Cold","last_name":"Start","phone":"555-0077","role":"customer"}'::jsonb);
select tests.create_supabase_user('viewer', 'viewer@test.com', null,
  '{"first_name":"View","last_name":"Er","phone":"555-0078","role":"customer"}'::jsonb);
select tests.create_supabase_user('booker', 'booker@test.com', null,
  '{"first_name":"Book","last_name":"Er","phone":"555-0079","role":"customer"}'::jsonb);
select tests.create_supabase_user('loner', 'loner@test.com', null,
  '{"first_name":"Lone","last_name":"R","phone":"555-0080","role":"customer"}'::jsonb);
select tests.create_supabase_user('hub', 'hub@test.com', null,
  '{"first_name":"Hub","last_name":"H","phone":"555-0081","role":"customer"}'::jsonb);
select tests.create_supabase_user('edge', 'edge@test.com', null,
  '{"first_name":"Edge","last_name":"Case","phone":"555-0082","role":"customer"}'::jsonb);
select tests.create_supabase_user('live', 'live@test.com', null,
  '{"first_name":"Live","last_name":"User","phone":"555-0083","role":"customer"}'::jsonb);
select tests.create_supabase_user('victim', 'victim@test.com', null,
  '{"first_name":"victim","last_name":"S","phone":"555-0084","role":"customer"}'::jsonb);
select tests.create_supabase_user('real1', 'real1@test.com', null,
  '{"first_name":"real1","last_name":"S","phone":"555-0085","role":"customer"}'::jsonb);
select tests.create_supabase_user('real2', 'real2@test.com', null,
  '{"first_name":"real2","last_name":"S","phone":"555-0086","role":"customer"}'::jsonb);
select tests.create_supabase_user('sy1', 'sy1@test.com', null,
  '{"first_name":"sy1","last_name":"S","phone":"555-0087","role":"customer"}'::jsonb);
select tests.create_supabase_user('sy2', 'sy2@test.com', null,
  '{"first_name":"sy2","last_name":"S","phone":"555-0088","role":"customer"}'::jsonb);
select tests.create_supabase_user('sy3', 'sy3@test.com', null,
  '{"first_name":"sy3","last_name":"S","phone":"555-0089","role":"customer"}'::jsonb);
select tests.create_supabase_user('sy4', 'sy4@test.com', null,
  '{"first_name":"sy4","last_name":"S","phone":"555-0090","role":"customer"}'::jsonb);
select tests.create_supabase_user('sy5', 'sy5@test.com', null,
  '{"first_name":"sy5","last_name":"S","phone":"555-0091","role":"customer"}'::jsonb);
select tests.create_supabase_user('sy6', 'sy6@test.com', null,
  '{"first_name":"sy6","last_name":"S","phone":"555-0092","role":"customer"}'::jsonb);

select set_config('tests.as_of', '2026-09-20 12:00:00+00', true);

-- FIXTURE-RESTAURANTS-BEGIN
insert into public.restaurants (owner_id, name, capacity)
  select tests.get_supabase_uid('owner_u'), n, 30
  from unnest(array['Sakura Sushi', 'Tokyo Ramen', 'Osaka Izakaya', 'Gaucho Steakhouse', 'Parrilla Grill', 'Bife Bar',
                    'Usamljeni', 'Stari Restoran', 'Zzz Arhiva']) as n;
-- FIXTURE-RESTAURANTS-END

-- === Settings and permissions ===
select is(
  (select profile from public.recommendation_settings),
  'demo',
  'the active profile defaults to demo'
);

-- === No data at all: the plain alphabetical list ===
select is(
  (select array_agg(r.name order by s.rank)
   from public.recommendation_scores(tests.get_supabase_uid('cold'), 'demo', current_setting('tests.as_of')::timestamptz) s
   join public.restaurants r on r.id = s.restaurant_id),
  array['Bife Bar', 'Gaucho Steakhouse', 'Osaka Izakaya', 'Parrilla Grill', 'Sakura Sushi', 'Stari Restoran', 'Tokyo Ramen', 'Usamljeni', 'Zzz Arhiva'],
  'with no events anywhere every score is 0 and ties fall back to alphabetical order by name'
);
select is(
  (select max(score) from public.recommendation_scores(tests.get_supabase_uid('cold'), 'demo', current_setting('tests.as_of')::timestamptz)),
  0::numeric,
  'and those scores really are all zero'
);

-- FIXTURE-BASE-BEGIN
insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
  select r.id, tests.get_supabase_uid(b.who), 2,
         current_setting('tests.as_of')::timestamptz - b.days_ago * interval '1 day',
         current_setting('tests.as_of')::timestamptz - b.days_ago * interval '1 day' + interval '90 minutes',
         'completed'
  from (values
    ('ana', 'Sakura Sushi', 10), ('ana', 'Tokyo Ramen', 25),
    ('boris', 'Sakura Sushi', 6), ('boris', 'Osaka Izakaya', 3),
    ('cvijeta', 'Tokyo Ramen', 14), ('cvijeta', 'Osaka Izakaya', 2),
    ('dejan', 'Gaucho Steakhouse', 8), ('dejan', 'Parrilla Grill', 20),
    ('emilija', 'Gaucho Steakhouse', 4), ('emilija', 'Bife Bar', 1)
  ) as b(who, rest, days_ago)
  join public.restaurants r on r.name = b.rest;

insert into public.favorites (user_id, restaurant_id, created_at)
  select tests.get_supabase_uid(b.who), r.id,
         current_setting('tests.as_of')::timestamptz - b.days_ago * interval '1 day'
  from (values ('ana', 'Sakura Sushi', 9), ('cvijeta', 'Osaka Izakaya', 2), ('dejan', 'Gaucho Steakhouse', 7)) as b(who, rest, days_ago)
  join public.restaurants r on r.name = b.rest;

insert into public.restaurant_views (user_id, restaurant_id, view_count, last_viewed_at)
  select tests.get_supabase_uid(b.who), r.id, b.n,
         current_setting('tests.as_of')::timestamptz - b.days_ago * interval '1 day'
  from (values ('ana', 'Osaka Izakaya', 2, 5), ('boris', 'Tokyo Ramen', 1, 4), ('emilija', 'Parrilla Grill', 3, 2)) as b(who, rest, n, days_ago)
  join public.restaurants r on r.name = b.rest;
-- FIXTURE-BASE-END

-- === Cold start: popularity only ===
select is(
  (select max(personalization) from public.recommendation_scores(tests.get_supabase_uid('cold'), 'demo', current_setting('tests.as_of')::timestamptz)),
  0::numeric,
  'a customer with no history gets personalization 0 (pure popularity)'
);
select is(
  (select (array_agg(r.name order by s.rank))[1:6]
   from public.recommendation_scores(tests.get_supabase_uid('cold'), 'demo', current_setting('tests.as_of')::timestamptz) s
   join public.restaurants r on r.id = s.restaurant_id),
  array['Osaka Izakaya', 'Gaucho Steakhouse', 'Sakura Sushi', 'Bife Bar', 'Tokyo Ramen', 'Parrilla Grill'],
  'the cold-start order is popularity: what was booked, favorited and viewed recently comes first'
);
select is(
  (select round(max(popularity_score), 6) from public.recommendation_scores(tests.get_supabase_uid('cold'), 'demo', current_setting('tests.as_of')::timestamptz)),
  1::numeric,
  'popularity is scaled so the most popular restaurant scores exactly 1'
);

-- === A customer with history: neighbors decide ===
select is(
  (select round(max(personalization), 4) from public.recommendation_scores(tests.get_supabase_uid('ana'), 'demo', current_setting('tests.as_of')::timestamptz)),
  0.8347::numeric,
  'Ana''s personalization = her total affinity / (total + 2) in the demo profile'
);
select is(
  (select (array_agg(r.name order by s.rank))[1:6]
   from public.recommendation_scores(tests.get_supabase_uid('ana'), 'demo', current_setting('tests.as_of')::timestamptz) s
   join public.restaurants r on r.id = s.restaurant_id),
  array['Osaka Izakaya', 'Sakura Sushi', 'Tokyo Ramen', 'Gaucho Steakhouse', 'Bife Bar', 'Parrilla Grill'],
  'Ana (Asian group): a restaurant her neighbors booked recently but she never did ranks first, the grill group ranks last'
);
select is(
  (select array_agg(r.name order by r.name)
   from public.recommendation_scores(tests.get_supabase_uid('ana'), 'demo', current_setting('tests.as_of')::timestamptz) s
   join public.restaurants r on r.id = s.restaurant_id
   where s.booked_before),
  array['Sakura Sushi', 'Tokyo Ramen'],
  'booked_before marks exactly the restaurants Ana has a completed or active booking at'
);
select is(
  (select s.similar_users
   from public.recommendation_scores(tests.get_supabase_uid('ana'), 'demo', current_setting('tests.as_of')::timestamptz) s
   join public.restaurants r on r.id = s.restaurant_id
   where r.name = 'Osaka Izakaya'),
  2,
  'two of Ana''s neighbors (Boris, Cvijeta) have a signal for Osaka; the count says how many, never who'
);
select is(
  (select (array_agg(r.name order by s.rank))[1:6]
   from public.recommendation_scores(tests.get_supabase_uid('dejan'), 'demo', current_setting('tests.as_of')::timestamptz) s
   join public.restaurants r on r.id = s.restaurant_id),
  array['Bife Bar', 'Gaucho Steakhouse', 'Parrilla Grill', 'Osaka Izakaya', 'Sakura Sushi', 'Tokyo Ramen'],
  'Dejan (grill group): the mirror image, with the Asian group last'
);
-- Scores are pinned too (to 4 decimals), not just the order: they are what
-- catches a wrong similarity weighting, a missing norm or a lost penalty.
select is(
  (select (array_agg(round(s.score, 4) order by s.rank))[1:6] from public.recommendation_scores(tests.get_supabase_uid('ana'), 'demo', current_setting('tests.as_of')::timestamptz) s),
  array[1.0000, 0.4258, 0.1329, 0.1197, 0.0663, 0.0281]::numeric[],
  'Ana''s six best scores (demo profile)'
);
select is(
  (select (array_agg(round(s.score, 4) order by s.rank))[1:6] from public.recommendation_scores(tests.get_supabase_uid('dejan'), 'demo', current_setting('tests.as_of')::timestamptz) s),
  array[0.8990, 0.6707, 0.2453, 0.1687, 0.1054, 0.0300]::numeric[],
  'Dejan''s six best scores (demo profile)'
);

-- === Recency: what similar people did recently outweighs what they did long ago ===
-- Ana's neighbors Boris (Osaka, 3 days ago) and Cvijeta (Osaka, 2 days ago) vs.
-- Tokyo, which Ana herself booked 25 days ago: the recent Osaka beats it.
select ok(
  (select (select s.rank from public.recommendation_scores(tests.get_supabase_uid('ana'), 'demo', current_setting('tests.as_of')::timestamptz) s
           join public.restaurants r on r.id = s.restaurant_id where r.name = 'Osaka Izakaya')
        < (select s.rank from public.recommendation_scores(tests.get_supabase_uid('ana'), 'demo', current_setting('tests.as_of')::timestamptz) s
           join public.restaurants r on r.id = s.restaurant_id where r.name = 'Tokyo Ramen')),
  'a recent booking by similar customers outranks a restaurant the customer booked long ago'
);
select is(
  public.recommendation_decay(current_setting('tests.as_of')::timestamptz - interval '7 days', current_setting('tests.as_of')::timestamptz, 7),
  0.5::numeric,
  'an event one half-life old weighs exactly half'
);
select is(
  public.recommendation_decay(current_setting('tests.as_of')::timestamptz + interval '3 days', current_setting('tests.as_of')::timestamptz, 7),
  1::numeric,
  'and one in the future (age 0) weighs its full amount'
);
select is(
  (select round(s.score / nullif(s.personalization * s.knn_score + (1 - s.personalization) * s.popularity_score, 0), 6)
   from public.recommendation_scores(tests.get_supabase_uid('ana'), 'demo', current_setting('tests.as_of')::timestamptz) s join public.restaurants r on r.id = s.restaurant_id
   where r.name = 'Osaka Izakaya'),
  1::numeric,
  'a restaurant Ana never booked keeps its full blended score'
);
select ok(
  (select s.score / nullif(s.personalization * s.knn_score + (1 - s.personalization) * s.popularity_score, 0) < 1
   from public.recommendation_scores(tests.get_supabase_uid('ana'), 'demo', current_setting('tests.as_of')::timestamptz) s join public.restaurants r on r.id = s.restaurant_id
   where r.name = 'Sakura Sushi'),
  'a restaurant she booked recently loses part of it (the repeat-visit penalty)'
);

-- === The two profiles ===
select is(
  (select round(max(personalization), 4) from public.recommendation_scores(tests.get_supabase_uid('ana'), 'realistic', current_setting('tests.as_of')::timestamptz)),
  0.5695::numeric,
  'the realistic profile trusts the neighbors less than the demo one for the same history (blend constant 10, not 2)'
);
select is(
  (select (array_agg(round(s.score, 4) order by s.rank))[1:6] from public.recommendation_scores(tests.get_supabase_uid('ana'), 'realistic', current_setting('tests.as_of')::timestamptz) s),
  array[1.0000, 0.5662, 0.3764, 0.3334, 0.1580, 0.1482]::numeric[],
  'Ana''s six best scores (realistic profile: slower decay, more neighbors)'
);
select throws_ok(
  $$select * from public.recommendation_scores(tests.get_supabase_uid('ana'), 'nepostojeci', now())$$,
  'P0001',
  'Nepoznat profil preporuka.',
  'an unknown profile is refused'
);

-- FIXTURE-EDGE-BEGIN
-- viewer: a single page view, right now. booker: a single (future) booking.
insert into public.restaurant_views (user_id, restaurant_id, view_count, last_viewed_at)
  select tests.get_supabase_uid('viewer'), id, 1, current_setting('tests.as_of')::timestamptz
  from public.restaurants where name = 'Sakura Sushi';
insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
  select id, tests.get_supabase_uid('booker'), 2,
         current_setting('tests.as_of')::timestamptz + interval '2 days',
         current_setting('tests.as_of')::timestamptz + interval '2 days 90 minutes', 'confirmed'
  from public.restaurants where name = 'Sakura Sushi';

-- loner: the only customer with a signal at Usamljeni, so nobody is similar.
insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
  select id, tests.get_supabase_uid('loner'), 2,
         current_setting('tests.as_of')::timestamptz - interval '3 days',
         current_setting('tests.as_of')::timestamptz - interval '3 days' + interval '90 minutes', 'completed'
  from public.restaurants where name = 'Usamljeni';

-- hub: completed at all six scenario restaurants (so many neighbors), and at
-- Zzz Arhiva, which is then archived (its events must vanish).
insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
  select id, tests.get_supabase_uid('hub'), 2,
         current_setting('tests.as_of')::timestamptz - interval '1 day',
         current_setting('tests.as_of')::timestamptz - interval '1 day' + interval '90 minutes', 'completed'
  from public.restaurants
  where name in ('Sakura Sushi', 'Tokyo Ramen', 'Osaka Izakaya', 'Gaucho Steakhouse', 'Parrilla Grill', 'Bife Bar', 'Zzz Arhiva');
insert into public.favorites (user_id, restaurant_id, created_at)
  select tests.get_supabase_uid('hub'), id, current_setting('tests.as_of')::timestamptz - interval '1 day'
  from public.restaurants where name = 'Zzz Arhiva';
insert into public.restaurant_views (user_id, restaurant_id, view_count, last_viewed_at)
  select tests.get_supabase_uid('hub'), id, 3, current_setting('tests.as_of')::timestamptz - interval '1 day'
  from public.restaurants where name = 'Zzz Arhiva';
update public.restaurants set archived_at = current_setting('tests.as_of')::timestamptz where name = 'Zzz Arhiva';

-- edge: the odd ones. Sakura: ongoing (4), plus a no_show and a cancelled that
-- must add nothing. Tokyo: completed with a confirmed order (5 + 1). Bife:
-- completed whose order was cancelled (5, no bonus). Osaka: a future booking.
-- Gaucho: 50 page views (capped). Parrilla: a 200-day-old favorite. Stari
-- Restoran: a booking 800 days ago (past the horizon). Usamljeni: only a no_show
-- and a cancelled booking. Plus an anonymized
-- booking (deleted account, no customer) at Sakura.
insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
  select r.id, tests.get_supabase_uid('edge'), 2,
         current_setting('tests.as_of')::timestamptz + b.start_offset,
         current_setting('tests.as_of')::timestamptz + b.start_offset + interval '90 minutes', b.status
  from (values
    ('Sakura Sushi',  interval '-30 minutes', 'ongoing'),
    ('Sakura Sushi',  interval '-5 days',     'no_show'),
    ('Sakura Sushi',  interval '-6 days',     'cancelled'),
    ('Osaka Izakaya', interval '3 days',      'confirmed'),
    ('Stari Restoran', interval '-800 days',  'completed'),
    ('Usamljeni',     interval '-3 days',    'no_show'),
    ('Usamljeni',     interval '-4 days',    'cancelled')
  ) as b(rest, start_offset, status)
  join public.restaurants r on r.name = b.rest;
insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
  select id, null, 2,
         current_setting('tests.as_of')::timestamptz - interval '1 day',
         current_setting('tests.as_of')::timestamptz - interval '1 day' + interval '90 minutes', 'completed'
  from public.restaurants where name = 'Sakura Sushi';

with tokyo as (
  insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
    select id, tests.get_supabase_uid('edge'), 2,
           current_setting('tests.as_of')::timestamptz - interval '2 days',
           current_setting('tests.as_of')::timestamptz - interval '2 days' + interval '90 minutes', 'completed'
    from public.restaurants where name = 'Tokyo Ramen'
    returning id, restaurant_id
)
insert into public.orders (restaurant_id, customer_id, status, reservation_id, confirmed_at)
  select restaurant_id, tests.get_supabase_uid('edge'), 'confirmed', id, current_setting('tests.as_of')::timestamptz - interval '2 days'
  from tokyo;

with bife as (
  insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
    select id, tests.get_supabase_uid('edge'), 2,
           current_setting('tests.as_of')::timestamptz - interval '1 day',
           current_setting('tests.as_of')::timestamptz - interval '1 day' + interval '90 minutes', 'completed'
    from public.restaurants where name = 'Bife Bar'
    returning id, restaurant_id
)
insert into public.orders (restaurant_id, customer_id, status, reservation_id)
  select restaurant_id, tests.get_supabase_uid('edge'), 'cancelled', id from bife;

insert into public.restaurant_views (user_id, restaurant_id, view_count, last_viewed_at)
  select tests.get_supabase_uid('edge'), id, 50, current_setting('tests.as_of')::timestamptz - interval '1 day'
  from public.restaurants where name = 'Gaucho Steakhouse';
insert into public.favorites (user_id, restaurant_id, created_at)
  select tests.get_supabase_uid('edge'), id, current_setting('tests.as_of')::timestamptz - interval '200 days'
  from public.restaurants where name = 'Parrilla Grill';
-- FIXTURE-EDGE-END

-- === The blend rises smoothly with history ===
select is(
  (select round(max(personalization), 6) from public.recommendation_scores(tests.get_supabase_uid('viewer'), 'demo', current_setting('tests.as_of')::timestamptz)),
  round(0.5 / (0.5 + 2), 6),
  'one page view (0.5) gives personalization 0.5 / 2.5 = 0.2, not a full switch to the neighbors'
);
select is(
  (select round(max(personalization), 6) from public.recommendation_scores(tests.get_supabase_uid('booker'), 'demo', current_setting('tests.as_of')::timestamptz)),
  round(4.0 / (4.0 + 2), 6),
  'one booking (4) gives personalization 4 / 6, about two thirds'
);
select is(
  (select max(personalization) from public.recommendation_scores(tests.get_supabase_uid('loner'), 'demo', current_setting('tests.as_of')::timestamptz)),
  0::numeric,
  'a customer nobody is similar to gets personalization 0 however much history they have'
);
select is(
  (select max(knn_score) from public.recommendation_scores(tests.get_supabase_uid('loner'), 'demo', current_setting('tests.as_of')::timestamptz)),
  0::numeric,
  'and no neighbor-based score at all'
);

-- === What counts, and how much (restaurant_affinities, both half-lives 30 days) ===
select is(
  (select round(a.affinity, 6)
   from public.restaurant_affinities(30, 30, current_setting('tests.as_of')::timestamptz) a
   join public.restaurants r on r.id = a.restaurant_id
   where a.user_id = tests.get_supabase_uid('edge') and r.name = 'Sakura Sushi'),
  round(4 * power(0.5::numeric, (30.0 / 1440) / 30), 6),
  'an ongoing booking weighs 4; the no_show and the cancelled one at the same restaurant add nothing'
);
select is(
  (select round(a.affinity, 6)
   from public.restaurant_affinities(30, 30, current_setting('tests.as_of')::timestamptz) a
   join public.restaurants r on r.id = a.restaurant_id
   where a.user_id = tests.get_supabase_uid('edge') and r.name = 'Tokyo Ramen'),
  round(6 * power(0.5::numeric, 2.0 / 30), 6),
  'a completed booking with a confirmed order weighs 5 + 1, decayed by its 2 days'
);
select is(
  (select round(a.affinity, 6)
   from public.restaurant_affinities(30, 30, current_setting('tests.as_of')::timestamptz) a
   join public.restaurants r on r.id = a.restaurant_id
   where a.user_id = tests.get_supabase_uid('edge') and r.name = 'Bife Bar'),
  round(5 * power(0.5::numeric, 1.0 / 30), 6),
  'a cancelled order does not add the +1'
);
select is(
  (select a.affinity
   from public.restaurant_affinities(30, 30, current_setting('tests.as_of')::timestamptz) a
   join public.restaurants r on r.id = a.restaurant_id
   where a.user_id = tests.get_supabase_uid('edge') and r.name = 'Osaka Izakaya'),
  4::numeric,
  'a future booking has age 0, so it weighs its full 4'
);
select is(
  (select round(a.affinity, 6)
   from public.restaurant_affinities(30, 30, current_setting('tests.as_of')::timestamptz) a
   join public.restaurants r on r.id = a.restaurant_id
   where a.user_id = tests.get_supabase_uid('edge') and r.name = 'Gaucho Steakhouse'),
  round(2 * power(0.5::numeric, 1.0 / 30), 6),
  '50 page views count as 2, the cap - less than one booking'
);
select is(
  (select round(a.affinity, 6)
   from public.restaurant_affinities(30, 30, current_setting('tests.as_of')::timestamptz) a
   join public.restaurants r on r.id = a.restaurant_id
   where a.user_id = tests.get_supabase_uid('edge') and r.name = 'Parrilla Grill'),
  round(3 * power(0.5::numeric, 200.0 / 30), 6),
  'a favorite weighs 3, faded by its age (200 days)'
);
select is_empty(
  $$select 1
    from public.restaurant_affinities(30, 30, current_setting('tests.as_of')::timestamptz) a
    join public.restaurants r on r.id = a.restaurant_id
    where a.user_id = tests.get_supabase_uid('edge') and r.name = 'Stari Restoran'$$,
  'a booking older than the 730-day horizon is ignored'
);
select is(
  (select count(*) from public.restaurant_affinities(30, 30, current_setting('tests.as_of')::timestamptz) where user_id is null),
  0::bigint,
  'an anonymized booking (no customer) contributes to nobody'
);
select is_empty(
  $$select 1
    from public.restaurant_affinities(30, 30, current_setting('tests.as_of')::timestamptz) a
    join public.restaurants r on r.id = a.restaurant_id
    where r.name = 'Zzz Arhiva'$$,
  'an archived restaurant has no affinities, whatever was booked, favorited or viewed there'
);
select is_empty(
  $$select 1
    from public.recommendation_scores(tests.get_supabase_uid('hub'), 'demo', current_setting('tests.as_of')::timestamptz) s
    join public.restaurants r on r.id = s.restaurant_id
    where r.name = 'Zzz Arhiva'$$,
  'and it is not in anybody''s ranking'
);

-- === k: how many neighbors are consulted ===
select ok(
  (select max(similar_users) <= 4 from public.recommendation_scores(tests.get_supabase_uid('hub'), 'demo', current_setting('tests.as_of')::timestamptz)),
  'the demo profile (k = 4) never counts more than 4 neighbors at a restaurant'
);
select ok(
  (select max(similar_users) > 4 from public.recommendation_scores(tests.get_supabase_uid('hub'), 'realistic', current_setting('tests.as_of')::timestamptz)),
  'the realistic profile (k = 30) consults more of the hub''s many neighbors'
);

-- === "Been there" means a booking ===
select is(
  (select array_agg(r.name order by r.name)
   from public.restaurant_affinities(30, 30, current_setting('tests.as_of')::timestamptz) a
   join public.restaurants r on r.id = a.restaurant_id
   where a.user_id = tests.get_supabase_uid('edge') and a.booking_affinity > 0),
  array['Bife Bar', 'Osaka Izakaya', 'Sakura Sushi', 'Tokyo Ramen'],
  'booking_affinity is the reservation part only: no favorite (Parrilla), page views (Gaucho), no_show/cancelled (Usamljeni) or booking past the horizon (Stari Restoran) has any'
);
select is(
  (select array_agg(r.name order by r.name)
   from public.recommendation_scores(tests.get_supabase_uid('edge'), 'demo', current_setting('tests.as_of')::timestamptz) s join public.restaurants r on r.id = s.restaurant_id
   where s.booked_before),
  array['Bife Bar', 'Osaka Izakaya', 'Sakura Sushi', 'Stari Restoran', 'Tokyo Ramen'],
  'booked_before counts completed and active bookings (ongoing, a confirmed one in the future) however old - it is a fact about the past, not a weight, so the 730-day horizon does not apply - and not a no_show or a cancelled one'
);
select ok(
  (select bool_and(round(s.score / nullif(s.personalization * s.knn_score + (1 - s.personalization) * s.popularity_score, 0), 6) = 1)
   from public.recommendation_scores(tests.get_supabase_uid('edge'), 'demo', current_setting('tests.as_of')::timestamptz) s join public.restaurants r on r.id = s.restaurant_id
   where r.name in ('Parrilla Grill', 'Gaucho Steakhouse')),
  'a restaurant the customer only favorited or viewed is not penalized as a repeat visit'
);

-- === Throwaway accounts cannot crowd out or outweigh real neighbors ===
-- An isolated scenario on four restaurants of its own (Sibil X/Y/Z/T):
--   victim   booked X (5 days ago) and Y (10)
--   real1    booked X (4) and Z (2);   real2  booked Y (8) and Z (3)
--   sy1-sy4  a single page view of X each, yesterday: the cheapest possible
--            accounts. Without evidence weighting their one-item vectors point
--            exactly like the victim's X, so they look MORE similar than the
--            real neighbors and (k = 4) fill the top-k on their own.
--   sy5-sy6  favorite X and the target T: try to steer the victim toward T.
-- Z is what the two real neighbors booked: the honest recommendation.
-- FIXTURE-SYBIL-BEGIN
insert into public.restaurants (owner_id, name, capacity)
  select tests.get_supabase_uid('owner_u'), n, 30
  from unnest(array['Sibil X', 'Sibil Y', 'Sibil Z', 'Sibil T']) as n;

insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
  select r.id, tests.get_supabase_uid(b.who), 2,
         current_setting('tests.as_of')::timestamptz - b.days_ago * interval '1 day',
         current_setting('tests.as_of')::timestamptz - b.days_ago * interval '1 day' + interval '90 minutes',
         'completed'
  from (values
    ('victim', 'Sibil X', 5), ('victim', 'Sibil Y', 10),
    ('real1', 'Sibil X', 4), ('real1', 'Sibil Z', 2),
    ('real2', 'Sibil Y', 8), ('real2', 'Sibil Z', 3)
  ) as b(who, rest, days_ago)
  join public.restaurants r on r.name = b.rest;

insert into public.restaurant_views (user_id, restaurant_id, view_count, last_viewed_at)
  select tests.get_supabase_uid(w.who), r.id, 1, current_setting('tests.as_of')::timestamptz - interval '1 day'
  from (values ('sy1'), ('sy2'), ('sy3'), ('sy4')) as w(who)
  join public.restaurants r on r.name = 'Sibil X';

insert into public.favorites (user_id, restaurant_id, created_at)
  select tests.get_supabase_uid(w.who), r.id, current_setting('tests.as_of')::timestamptz - interval '1 day'
  from (values ('sy5'), ('sy6')) as w(who)
  join public.restaurants r on r.name in ('Sibil X', 'Sibil T');
-- FIXTURE-SYBIL-END

select is(
  (select s.similar_users
   from public.recommendation_scores(tests.get_supabase_uid('victim'), 'demo', current_setting('tests.as_of')::timestamptz) s
   join public.restaurants r on r.id = s.restaurant_id where r.name = 'Sibil Z'),
  2,
  'both real neighbors still count at Z: the four one-view accounts did not fill the top-k (without evidence weighting Z has 0 neighbors)'
);
select ok(
  (select (select s.rank from public.recommendation_scores(tests.get_supabase_uid('victim'), 'demo', current_setting('tests.as_of')::timestamptz) s
           join public.restaurants r on r.id = s.restaurant_id where r.name = 'Sibil Z')
        < (select s.rank from public.recommendation_scores(tests.get_supabase_uid('victim'), 'demo', current_setting('tests.as_of')::timestamptz) s
           join public.restaurants r on r.id = s.restaurant_id where r.name = 'Sibil T')),
  'what the real neighbors booked (Z) ranks above the restaurant the favorite-only accounts are pushing (T)'
);
select is(
  (select array_agg(round(x.score, 4) order by x.name)
   from (select r.name, s.score
         from public.recommendation_scores(tests.get_supabase_uid('victim'), 'demo', current_setting('tests.as_of')::timestamptz) s
         join public.restaurants r on r.id = s.restaurant_id
         where r.name in ('Sibil X', 'Sibil Y', 'Sibil Z', 'Sibil T')) x),
  array[0.3464, 0.7094, 0.2325, 0.8828]::numeric[],
  'the victim''s scores at T, X, Y, Z (in name order) - pinned, so any change to how evidence weights similarity shows up'
);

-- === Who may call what ===
-- live: history placed relative to the REAL now(). The public wrapper ranks at
-- now(), so events fixed at tests.as_of would one day age past the 730-day
-- horizon and turn these tests vacuous (every ranking alphabetical).
insert into public.reservations (restaurant_id, customer_id, party_size, starts_at, ends_at, status)
  select r.id, tests.get_supabase_uid('live'), 2,
         now() - b.days * interval '1 day',
         now() - b.days * interval '1 day' + interval '90 minutes', 'completed'
  from (values ('Sakura Sushi', 1), ('Osaka Izakaya', 2)) as b(rest, days)
  join public.restaurants r on r.name = b.rest;
insert into public.favorites (user_id, restaurant_id, created_at)
  select tests.get_supabase_uid('live'), id, now() from public.restaurants where name = 'Tokyo Ramen';

select set_config('tests.live_ranking',
  (select string_agg(restaurant_id::text, ',' order by rank)
   from public.recommendation_scores(tests.get_supabase_uid('live'), 'demo', now())), true);
select set_config('tests.live_ranking_realistic',
  (select string_agg(restaurant_id::text, ',' order by rank)
   from public.recommendation_scores(tests.get_supabase_uid('live'), 'realistic', now())), true);
select set_config('tests.live_pers_demo',
  (select round(max(personalization), 4)::text
   from public.recommendation_scores(tests.get_supabase_uid('live'), 'demo', now())), true);
select set_config('tests.live_pers_realistic',
  (select round(max(personalization), 4)::text
   from public.recommendation_scores(tests.get_supabase_uid('live'), 'realistic', now())), true);
select set_config('tests.live_popular',
  (select string_agg(restaurant_id::text, ',' order by rank)
   from public.recommendation_scores(tests.get_supabase_uid('live'), 'demo', now())
   where popularity_score > 0), true);

select tests.clear_authentication();
select throws_ok(
  $$select * from public.recommend_restaurants()$$,
  '42501',
  null,
  'an unauthenticated (anon) caller cannot execute recommend_restaurants'
);

select tests.authenticate_as('live');
select throws_ok(
  $$select * from public.recommendation_scores(tests.get_supabase_uid('boris'), 'demo', now())$$,
  '42501',
  null,
  'a customer cannot call the scoring core directly (which would let them rank as somebody else)'
);
select throws_ok(
  $$select * from public.restaurant_affinities(30, 30, now())$$,
  '42501',
  null,
  'nor read every customer''s affinities'
);
select throws_ok(
  $$select * from public.recommendation_params('demo')$$,
  '42501',
  null,
  'nor the parameter function'
);
select throws_ok(
  $$select * from public.recommendation_settings$$,
  '42501',
  null,
  'the settings table is not reachable from the Data API'
);
select is(
  (select string_agg(restaurant_id::text, ',' order by rank) from public.recommend_restaurants()),
  current_setting('tests.live_ranking'),
  'recommend_restaurants() returns the caller''s own ranking, in the default (demo) profile'
);
select ok(
  (select max(personalization) > 0 from public.recommend_restaurants()),
  'and it is really ranked from their history, not the alphabetical fallback'
);
select is(
  (select string_agg(restaurant_id::text, ',' order by rank) from public.recommend_restaurants() where popular),
  current_setting('tests.live_popular'),
  'the popular flag is exactly "some customer has a signal at this restaurant"'
);

select tests.authenticate_as('owner_u');
select throws_ok(
  $$select * from public.recommend_restaurants()$$,
  'P0001',
  'Samo nalozi tipa kupac mogu dobijati preporuke.',
  'an owner-role account gets no recommendations'
);

-- The wrapper follows the switch in the settings table (it takes no profile argument).
reset role;
update public.recommendation_settings set profile = 'realistic';
select tests.authenticate_as('live');
select is(
  (select string_agg(restaurant_id::text, ',' order by rank) from public.recommend_restaurants()),
  current_setting('tests.live_ranking_realistic'),
  'after switching the setting to realistic, the wrapper ranks with the realistic profile'
);
select is(
  (select round(max(personalization), 4)::text from public.recommend_restaurants()),
  current_setting('tests.live_pers_realistic'),
  'its personalization is the realistic one'
);
select isnt(
  current_setting('tests.live_pers_demo'),
  current_setting('tests.live_pers_realistic'),
  'and the two profiles really do differ for this customer, so the switch above proves something'
);

-- What the wrapper returns: no scores, no way to name a profile.
reset role;
select is(
  pg_get_function_result('public.recommend_restaurants()'::regprocedure),
  'TABLE(rank integer, restaurant_id uuid, personalization numeric, similar_users integer, booked_before boolean, popular boolean)',
  'the result has no scores (the neighbors'' activity scaled to 0..1 would let a customer read another customer''s behavior off it) and no customer ids'
);
select has_function('public', 'recommend_restaurants', array[]::text[], 'recommend_restaurants() takes no arguments');
select hasnt_function(
  'public', 'recommend_restaurants', array['text'],
  'and there is no profile argument (a caller could pick a second, differently-decayed measurement with it)'
);

select * from finish();
rollback;
