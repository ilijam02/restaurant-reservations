-- Coverage for supabase/migrations/20260918120000_auto_finish_reservations.sql:
-- finish_expired_reservations() moves ongoing -> completed and
-- confirmed/preparing_order/order_prepared -> no_show once ends_at has
-- passed, leaves not-yet-ended and already-terminal reservations alone, and
-- is callable only by the function's owner (which is who pg_cron runs it
-- as), never an app role.
--
-- J's Kafana has no layout and no sections, so bookings are plain
-- restaurant-capacity ones with no table rows to set up; each reservation
-- gets its own party size so it can be identified below. Statuses and
-- "already ended" times are set directly with service_role, same
-- convention as 70-capacity-guards.sql/80-reservation-status-lifecycle.sql
-- (create_reservation() refuses a past start, and this suite can't wait for
-- real time to pass). The sweep itself runs as the table owner (reset
-- role) since it's revoked from every app role, including service_role.
begin;
select plan(4);

select tests.create_supabase_user('owner_f', 'ownerf@test.com', null,
  '{"first_name":"Owner","last_name":"F","phone":"555-0013","role":"owner"}'::jsonb);
select tests.create_supabase_user('customer_5', 'customer5@test.com', null,
  '{"first_name":"Cust","last_name":"Five","phone":"555-0014","role":"customer"}'::jsonb);

select tests.authenticate_as('owner_f');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_f'), 'J''s Kafana');
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'J''s Kafana'), d, 0, 1440
  from generate_series(0, 6) as d;

select tests.authenticate_as('customer_5');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'J''s Kafana'),
      p, now() + interval '5 hours', 60
    ) from generate_series(1, 7) as p$$,
  'customer_5 books seven plain-capacity reservations, party sizes 1-7'
);

select tests.authenticate_as_service_role();
update public.reservations set status = 'preparing_order' where party_size = 2;
update public.reservations set status = 'order_prepared' where party_size = 3;
update public.reservations set status = 'ongoing' where party_size in (4, 6);
update public.reservations set status = 'cancelled' where party_size = 7;
-- Parties 1-4 and 7 have already ended; 5 (confirmed) and 6 (ongoing)
-- still have time left.
update public.reservations
  set starts_at = now() - interval '2 hours', ends_at = now() - interval '1 hour'
  where party_size in (1, 2, 3, 4, 7);

select tests.authenticate_as('customer_5');
select throws_ok(
  $$select public.finish_expired_reservations()$$,
  '42501',
  null,
  'an app role cannot call the sweep function directly'
);

reset role;
select is(
  (select count(*)::integer from cron.job where jobname = 'finish-expired-reservations' and active),
  1,
  'the finish-expired-reservations cron job is scheduled and active'
);

select public.finish_expired_reservations();

select tests.authenticate_as_service_role();
select results_eq(
  $$select party_size, status from public.reservations order by party_size$$,
  $$values
    (1, 'no_show'::text),
    (2, 'no_show'::text),
    (3, 'no_show'::text),
    (4, 'completed'::text),
    (5, 'confirmed'::text),
    (6, 'ongoing'::text),
    (7, 'cancelled'::text)$$,
  'ended confirmed/preparing_order/order_prepared became no_show, ended ongoing became completed; unended and cancelled reservations were left alone'
);

select * from finish();
rollback;
