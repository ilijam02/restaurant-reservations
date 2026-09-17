-- Coverage for supabase/migrations/20260913140000_protect_capacity_from_active_reservations.sql
-- and its three follow-ups (20260917100000_detailed_active_reservation_errors.sql,
-- 20260917110000_tables_with_active_reservations_layout_name.sql,
-- 20260917120000_sections_peak_reserved_capacity_batch.sql): deleting a
-- table/section, or shrinking restaurants.capacity/sections.capacity, must
-- be rejected while a confirmed, not-yet-ended reservation depends on it,
-- and allowed again once that reservation is cancelled (or, for the
-- capacity checks, once the new number is still large enough). The
-- tables_with_active_reservations()/sections_with_active_reservations()/
-- sections_peak_reserved_capacity() pre-check functions the owner's edit
-- form calls before attempting any delete or section capacity decrease are
-- covered directly, rather than by asserting the trigger's raised message
-- text - that text now embeds a formatted reservation date/time, which
-- would make an exact-string assertion here depend on exactly when the
-- suite happens to run.
--
-- "Active" reservations here are created via create_reservation() as usual
-- (starting in the future, same as every other test file); "no longer
-- active" ones are simulated with a direct service_role update to
-- reservations.status, since there's no cancel-a-reservation feature yet to
-- exercise through the app's own RPC surface (see ISSUES.md's Customer
-- backlog).
begin;
select plan(21);

select tests.create_supabase_user('owner_c', 'ownerc@test.com', null,
  '{"first_name":"Owner","last_name":"C","phone":"555-0007","role":"owner"}'::jsonb);
select tests.create_supabase_user('customer_3', 'customer3@test.com', null,
  '{"first_name":"Cust","last_name":"Three","phone":"555-0008","role":"customer"}'::jsonb);

-- === F's Bistro: active layout - table deletion blocked by
-- reservation_tables ===
select tests.authenticate_as('owner_c');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_c'), 'F''s Bistro');
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'F''s Bistro'), d, 0, 1440
  from generate_series(0, 6) as d;
insert into public.layouts (restaurant_id, name, is_active)
  values ((select id from public.restaurants where name = 'F''s Bistro'), 'Raspored 1', true);
insert into public.tables (restaurant_id, layout_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'F''s Bistro'),
    (select id from public.layouts where name = 'Raspored 1'),
    'Sto A', 4, 0, 0, 2, 2
  );
insert into public.tables (restaurant_id, layout_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'F''s Bistro'),
    (select id from public.layouts where name = 'Raspored 1'),
    'Sto B', 4, 4, 0, 2, 2
  );

select tests.authenticate_as('customer_3');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'F''s Bistro'),
      4,
      (date_trunc('day', now()) + interval '1 day 12 hours'),
      60,
      null,
      array[(select id from public.tables where name = 'Sto A')]
    )$$,
  'customer_3 books Sto A for tomorrow'
);

select tests.authenticate_as('owner_c');

-- tables_with_active_reservations() is what the owner's edit form calls
-- before attempting any delete, so it can report every blocker in one save
-- instead of discovering them one .delete() at a time. layout_name is
-- reported too, since table names are only unique per layout (not per
-- restaurant) - the form uses it to group its message once a save spans
-- more than one layout.
select results_eq(
  $$select table_name, layout_name, party_size from public.tables_with_active_reservations(
      array[(select id from public.tables where name = 'Sto A')]
    )$$,
  $$values ('Sto A'::text, 'Raspored 1'::text, 4)$$,
  'tables_with_active_reservations reports Sto A (its layout, and party size) as blocked'
);

select is_empty(
  $$select table_id from public.tables_with_active_reservations(
      array[(select id from public.tables where name = 'Sto B')]
    )$$,
  'tables_with_active_reservations reports nothing for an unbooked table'
);

select throws_ok(
  $$delete from public.tables where name = 'Sto A'$$,
  'P0001',
  null,
  'deleting a table with an active reservation is rejected'
);

select lives_ok(
  $$delete from public.tables where name = 'Sto B'$$,
  'deleting an unrelated, unbooked table on the same layout still works'
);

-- Simulate the reservation no longer being active (no cancel feature exists
-- yet to exercise via the app's own RPC surface).
select tests.authenticate_as_service_role();
update public.reservations set status = 'cancelled'
  where restaurant_id = (select id from public.restaurants where name = 'F''s Bistro') and party_size = 4;

select tests.authenticate_as('owner_c');
select lives_ok(
  $$delete from public.tables where name = 'Sto A'$$,
  'deleting the same table succeeds once its reservation is no longer active'
);

-- Whole-layout deletion cascades through tables, so the per-table trigger
-- fires during the cascade too, not just on a direct `delete from tables`.
insert into public.tables (restaurant_id, layout_id, name, seats, x, y, width, height)
  values (
    (select id from public.restaurants where name = 'F''s Bistro'),
    (select id from public.layouts where name = 'Raspored 1'),
    'Sto C', 4, 0, 0, 2, 2
  );
select tests.authenticate_as('customer_3');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'F''s Bistro'),
      4,
      (date_trunc('day', now()) + interval '2 days 12 hours'),
      60,
      null,
      array[(select id from public.tables where name = 'Sto C')]
    )$$,
  'customer_3 books Sto C for the layout-cascade check'
);

select tests.authenticate_as('owner_c');
select throws_ok(
  $$delete from public.layouts where name = 'Raspored 1'$$,
  'P0001',
  null,
  'deleting a whole layout is rejected while one of its tables has an active reservation'
);

select tests.authenticate_as_service_role();
update public.reservations set status = 'cancelled'
  where restaurant_id = (select id from public.restaurants where name = 'F''s Bistro') and party_size = 4;

select tests.authenticate_as('owner_c');
select lives_ok(
  $$delete from public.layouts where name = 'Raspored 1'$$,
  'deleting the layout succeeds once no table on it has an active reservation'
);

-- === G's Diner: plain baseline capacity - decrease blocked by peak load ===
insert into public.restaurants (owner_id, name, capacity) values (tests.get_supabase_uid('owner_c'), 'G''s Diner', 10);
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'G''s Diner'), d, 0, 1440
  from generate_series(0, 6) as d;

select tests.authenticate_as('customer_3');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'G''s Diner'),
      6,
      (date_trunc('day', now()) + interval '1 day 12 hours'),
      60
    )$$,
  'customer_3 books 6 of 10 seats at G''s Diner for tomorrow'
);

select tests.authenticate_as('owner_c');
select throws_ok(
  $$update public.restaurants set capacity = 5 where name = 'G''s Diner'$$,
  'P0001',
  'Kapacitet ne može biti manji od 6 - toliko gostiju već ima potvrđenu rezervaciju u istom terminu.',
  'shrinking restaurant capacity below the peak already-booked load is rejected'
);

select lives_ok(
  $$update public.restaurants set capacity = 6 where name = 'G''s Diner'$$,
  'shrinking capacity down to exactly the peak booked load is allowed'
);

select lives_ok(
  $$update public.restaurants set capacity = null where name = 'G''s Diner'$$,
  'setting capacity to unlimited (null) is always allowed'
);

select lives_ok(
  $$update public.restaurants set capacity = 20 where name = 'G''s Diner'$$,
  'increasing capacity is always allowed'
);

-- === H's Terrace: sections only - section capacity decrease and section
-- delete both blocked by reservation_sections ===
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_c'), 'H''s Terrace');
insert into public.restaurant_hours (restaurant_id, day_of_week, start_minute, end_minute)
  select (select id from public.restaurants where name = 'H''s Terrace'), d, 0, 1440
  from generate_series(0, 6) as d;
insert into public.sections (restaurant_id, name, capacity, color_index)
  values ((select id from public.restaurants where name = 'H''s Terrace'), 'Basta', 10, 0);

select tests.authenticate_as('customer_3');
select lives_ok(
  $$select public.create_reservation(
      (select id from public.restaurants where name = 'H''s Terrace'),
      7,
      (date_trunc('day', now()) + interval '1 day 12 hours'),
      60
    )$$,
  'customer_3 books 7 of Basta''s 10 seats for tomorrow'
);

select tests.authenticate_as('owner_c');

-- sections_peak_reserved_capacity() is what the owner's edit form calls
-- before the temp-rename-then-update dance for a section capacity change,
-- to avoid attempting (and having partially committed) a doomed update -
-- see ISSUES.md's Decided note on the __tmp_<id> corruption bug this fixed.
select results_eq(
  $$select section_name, peak_capacity from public.sections_peak_reserved_capacity(
      array[(select id from public.sections where name = 'Basta')]
    )$$,
  $$values ('Basta'::text, 7)$$,
  'sections_peak_reserved_capacity reports Basta''s peak reserved capacity'
);

select throws_ok(
  $$update public.sections set capacity = 5 where name = 'Basta'$$,
  'P0001',
  'Kapacitet sekcije ne može biti manji od 7 - toliko gostiju već ima potvrđenu rezervaciju u istom terminu.',
  'shrinking section capacity below the peak already-booked load is rejected'
);

select lives_ok(
  $$update public.sections set capacity = 7 where name = 'Basta'$$,
  'shrinking section capacity down to exactly the peak booked load is allowed'
);

select results_eq(
  $$select section_name, party_size from public.sections_with_active_reservations(
      array[(select id from public.sections where name = 'Basta')]
    )$$,
  $$values ('Basta'::text, 7)$$,
  'sections_with_active_reservations reports Basta (and its party size) as blocked'
);

select throws_ok(
  $$delete from public.sections where name = 'Basta'$$,
  'P0001',
  null,
  'deleting a section with an active reservation is rejected'
);

select tests.authenticate_as_service_role();
update public.reservations set status = 'cancelled'
  where restaurant_id = (select id from public.restaurants where name = 'H''s Terrace') and party_size = 7;

select tests.authenticate_as('owner_c');
select lives_ok(
  $$delete from public.sections where name = 'Basta'$$,
  'deleting the section succeeds once its reservation is no longer active'
);

select * from finish();
rollback;
