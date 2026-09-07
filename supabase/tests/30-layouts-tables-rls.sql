-- RLS coverage for public.layouts and public.tables (see
-- supabase/migrations/20260907091500_create_tables.sql,
-- .../20260907120000_create_layouts.sql, and
-- .../20260908110000_tables_rls_verify_layout_and_section_restaurant.sql).
--
-- The cross-restaurant insert/update assertions below are the regression
-- test for the gap the last migration fixed: the original tables
-- INSERT/UPDATE policies only checked that restaurant_id belonged to the
-- caller, never that layout_id/section_id actually belonged to that same
-- restaurant - so an owner could attach their own restaurant's table to
-- another owner's layout or section as long as they knew its id.
begin;
select plan(15);

select tests.rls_enabled('public', 'layouts');
select tests.rls_enabled('public', 'tables');

select tests.create_supabase_user('owner_a', 'ownera@test.com', null,
  '{"first_name":"Owner","last_name":"A","phone":"555-0001","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_b', 'ownerb@test.com', null,
  '{"first_name":"Owner","last_name":"B","phone":"555-0002","role":"owner"}'::jsonb);

-- Setup (not asserted): each owner creates their own restaurant, a layout,
-- and a section.
select tests.authenticate_as('owner_a');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_a'), 'A''s Bistro');
insert into public.layouts (restaurant_id, name)
  values ((select id from public.restaurants where name = 'A''s Bistro'), 'A Layout');
insert into public.sections (restaurant_id, name, capacity, color_index)
  values ((select id from public.restaurants where name = 'A''s Bistro'), 'A Section', 4, 0);

select tests.authenticate_as('owner_b');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_b'), 'B''s Diner');
insert into public.layouts (restaurant_id, name)
  values ((select id from public.restaurants where name = 'B''s Diner'), 'B Layout');
insert into public.sections (restaurant_id, name, capacity, color_index)
  values ((select id from public.restaurants where name = 'B''s Diner'), 'B Section', 4, 0);

-- Owner B cannot create a layout under owner A's restaurant.
select throws_ok(
  $$insert into public.layouts (restaurant_id, name)
    values ((select id from public.restaurants where name = 'A''s Bistro'), 'Spoofed Layout')$$,
  '42501',
  null,
  'owner_b cannot add a layout to owner_a''s restaurant'
);

-- Owner A can add a table to their own restaurant/layout/section.
select tests.authenticate_as('owner_a');
select lives_ok(
  $$insert into public.tables (restaurant_id, layout_id, section_id, name, seats, x, y, width, height)
    values (
      (select id from public.restaurants where name = 'A''s Bistro'),
      (select id from public.layouts where name = 'A Layout'),
      (select id from public.sections where name = 'A Section'),
      'Table 1', 4, 0, 0, 2, 2
    )$$,
  'owner_a can add a table to their own restaurant, layout, and section'
);

-- Owner A cannot add a table under their own restaurant_id but pointed at
-- owner B's layout - the cross-restaurant reference gap the RLS fix closes.
select throws_ok(
  $$insert into public.tables (restaurant_id, layout_id, section_id, name, seats, x, y, width, height)
    values (
      (select id from public.restaurants where name = 'A''s Bistro'),
      (select id from public.layouts where name = 'B Layout'),
      null, 'Cross-restaurant layout', 4, 0, 0, 2, 2
    )$$,
  '42501',
  null,
  'owner_a cannot attach a table to owner_b''s layout, even under their own restaurant_id'
);

-- Same for section_id.
select throws_ok(
  $$insert into public.tables (restaurant_id, layout_id, section_id, name, seats, x, y, width, height)
    values (
      (select id from public.restaurants where name = 'A''s Bistro'),
      (select id from public.layouts where name = 'A Layout'),
      (select id from public.sections where name = 'B Section'),
      'Cross-restaurant section', 4, 2, 0, 2, 2
    )$$,
  '42501',
  null,
  'owner_a cannot attach a table to owner_b''s section, even under their own restaurant_id'
);

-- Owner A cannot update their own table to point at owner B's layout
-- either. This row *is* visible to the UPDATE (it passes USING, since
-- restaurant_id is still owner_a's own restaurant) - it's the resulting
-- new row that fails WITH CHECK, which Postgres reports as an error
-- rather than silently affecting zero rows (unlike the USING-side denials
-- above/below, where the row isn't visible to the caller at all).
select throws_ok(
  $$update public.tables set layout_id = (select id from public.layouts where name = 'B Layout')
    where name = 'Table 1'$$,
  '42501',
  null,
  'owner_a cannot reassign their table to owner_b''s layout'
);

-- ...nor owner B's section.
select throws_ok(
  $$update public.tables set section_id = (select id from public.sections where name = 'B Section')
    where name = 'Table 1'$$,
  '42501',
  null,
  'owner_a cannot reassign their table to owner_b''s section'
);

-- A legitimate same-restaurant update still works.
select results_eq(
  $$update public.tables set seats = 6 where name = 'Table 1' returning seats$$,
  ARRAY[6],
  'owner_a can update their own table within their own restaurant'
);

-- Owner B cannot update owner A's layout.
select tests.authenticate_as('owner_b');
select results_eq(
  $$update public.layouts set name = 'Hacked' where name = 'A Layout' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot update owner_a''s layout'
);

-- Owner B cannot update owner A's table.
select results_eq(
  $$update public.tables set seats = 99 where name = 'Table 1' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot update owner_a''s table'
);

-- Owner B cannot delete owner A's table.
select results_eq(
  $$delete from public.tables where name = 'Table 1' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot delete owner_a''s table'
);

-- Owner B cannot delete owner A's layout.
select results_eq(
  $$delete from public.layouts where name = 'A Layout' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot delete owner_a''s layout'
);

-- Owner A can delete their own table.
select tests.authenticate_as('owner_a');
select results_eq(
  $$delete from public.tables where name = 'Table 1' returning 1$$,
  ARRAY[1],
  'owner_a can delete their own table'
);

-- Owner A can delete their own layout.
select results_eq(
  $$delete from public.layouts where name = 'A Layout' returning 1$$,
  ARRAY[1],
  'owner_a can delete their own layout'
);

select * from finish();
rollback;
