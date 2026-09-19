-- claim_geocode_slot() (supabase/migrations/20260919160000_geocode_rate_limit.sql):
-- the app-wide 1-request-per-second throttle in front of the public Nominatim
-- geocoder. Only owner-role accounts may claim; the slot is global, not per user.
begin;
select plan(9);

select tests.rls_enabled('public', 'geocode_rate_limit');

select tests.create_supabase_user('owner_a', 'ownera@test.com', null,
  '{"first_name":"Owner","last_name":"A","phone":"555-0001","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_b', 'ownerb@test.com', null,
  '{"first_name":"Owner","last_name":"B","phone":"555-0002","role":"owner"}'::jsonb);
select tests.create_supabase_user('customer_a', 'customera@test.com', null,
  '{"first_name":"Customer","last_name":"A","phone":"555-0004","role":"customer"}'::jsonb);

-- The table is only reachable through the function.
select tests.authenticate_as('owner_a');
select throws_ok(
  $$select * from public.geocode_rate_limit$$,
  '42501',
  null,
  'an owner cannot read the throttle table directly'
);

-- First claim gets the slot...
select is(
  public.claim_geocode_slot(),
  true,
  'an owner can claim the slot when it is free'
);

-- ...and the very next one - by anyone - does not: the slot is global.
select is(
  public.claim_geocode_slot(),
  false,
  'a second claim right after is refused'
);

select tests.authenticate_as('owner_b');
select is(
  public.claim_geocode_slot(),
  false,
  'a different owner is refused too - the limit is app-wide, not per user'
);

-- Once the window has passed the slot is available again. (Simulated by
-- resetting the timestamp as the table owner instead of sleeping.)
reset role;
update public.geocode_rate_limit set last_call_at = clock_timestamp() - interval '2 seconds';

select tests.authenticate_as('owner_b');
select is(
  public.claim_geocode_slot(),
  true,
  'the slot is claimable again after the window'
);

-- Non-owner roles never get a slot, even when it is free.
reset role;
update public.geocode_rate_limit set last_call_at = '-infinity';

select tests.authenticate_as('customer_a');
select is(
  public.claim_geocode_slot(),
  false,
  'a customer-role account cannot claim the slot'
);

-- ...and the refused claim did not consume it.
select tests.authenticate_as('owner_a');
select is(
  public.claim_geocode_slot(),
  true,
  'a refused claim leaves the slot free for an owner'
);

-- Not callable without signing in.
select tests.clear_authentication();
select throws_ok(
  $$select public.claim_geocode_slot()$$,
  '42501',
  null,
  'anon cannot call claim_geocode_slot()'
);

select * from finish();
rollback;
