-- RLS coverage for public.menu_categories, public.menu_items,
-- public.menu_item_options, and public.menu_item_option_choices (see
-- supabase/migrations/20260911090000_create_menu_categories.sql,
-- .../20260911091500_create_menu_items.sql,
-- .../20260911093000_create_menu_item_options.sql, and
-- .../20260911094500_create_menu_item_option_choices.sql).
--
-- menu_items.category_id gets the same cross-restaurant check as
-- tables.section_id/layout_id (see 30-layouts-tables-rls.sql) - an owner's
-- own restaurant_id isn't enough, category_id must belong to that same
-- restaurant too. menu_item_options/menu_item_option_choices have no
-- restaurant_id column at all - ownership is checked by joining up through
-- menu_item_id (and, for choices, option_id -> menu_item_id) to the
-- item's restaurant, same reasoning as tables being scoped through
-- layout_id rather than duplicating the ownership check at every level.
begin;
select plan(22);

select tests.rls_enabled('public', 'menu_categories');
select tests.rls_enabled('public', 'menu_items');
select tests.rls_enabled('public', 'menu_item_options');
select tests.rls_enabled('public', 'menu_item_option_choices');

select tests.create_supabase_user('owner_a', 'ownera@test.com', null,
  '{"first_name":"Owner","last_name":"A","phone":"555-0001","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_b', 'ownerb@test.com', null,
  '{"first_name":"Owner","last_name":"B","phone":"555-0002","role":"owner"}'::jsonb);

-- Setup (not asserted): each owner creates their own restaurant and a
-- menu category.
select tests.authenticate_as('owner_a');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_a'), 'A''s Bistro');
insert into public.menu_categories (restaurant_id, name)
  values ((select id from public.restaurants where name = 'A''s Bistro'), 'A Category');

select tests.authenticate_as('owner_b');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_b'), 'B''s Diner');
insert into public.menu_categories (restaurant_id, name)
  values ((select id from public.restaurants where name = 'B''s Diner'), 'B Category');

-- Owner B cannot create a menu category under owner A's restaurant.
select throws_ok(
  $$insert into public.menu_categories (restaurant_id, name)
    values ((select id from public.restaurants where name = 'A''s Bistro'), 'Spoofed Category')$$,
  '42501',
  null,
  'owner_b cannot add a menu category to owner_a''s restaurant'
);

select tests.authenticate_as('owner_a');

-- Owner A can add an item to their own restaurant/category.
select lives_ok(
  $$insert into public.menu_items (restaurant_id, category_id, name, price)
    values (
      (select id from public.restaurants where name = 'A''s Bistro'),
      (select id from public.menu_categories where name = 'A Category'),
      'A Item', 500
    )$$,
  'owner_a can add an item to their own restaurant and category'
);

-- Owner A can also add an uncategorized item (category_id null).
select lives_ok(
  $$insert into public.menu_items (restaurant_id, category_id, name, price)
    values ((select id from public.restaurants where name = 'A''s Bistro'), null, 'A Uncategorized Item', 300)$$,
  'owner_a can add an uncategorized item'
);

-- Owner A cannot add an item under their own restaurant_id but pointed at
-- owner B's category - the cross-restaurant reference gap tables.section_id
-- already guards against, mirrored here.
select throws_ok(
  $$insert into public.menu_items (restaurant_id, category_id, name, price)
    values (
      (select id from public.restaurants where name = 'A''s Bistro'),
      (select id from public.menu_categories where name = 'B Category'),
      'Cross-restaurant item', 500
    )$$,
  '42501',
  null,
  'owner_a cannot attach an item to owner_b''s category, even under their own restaurant_id'
);

-- Owner A cannot update their own item to point at owner B's category
-- either.
select throws_ok(
  $$update public.menu_items set category_id = (select id from public.menu_categories where name = 'B Category')
    where name = 'A Item'$$,
  '42501',
  null,
  'owner_a cannot reassign their item to owner_b''s category'
);

-- A legitimate same-restaurant update still works.
select results_eq(
  $$update public.menu_items set price = 600 where name = 'A Item' returning price$$,
  ARRAY[600.00],
  'owner_a can update their own item within their own restaurant'
);

select tests.authenticate_as('owner_b');

-- Owner B cannot update owner A's item.
select results_eq(
  $$update public.menu_items set price = 1 where name = 'A Item' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot update owner_a''s item'
);

-- Owner B cannot delete owner A's item.
select results_eq(
  $$delete from public.menu_items where name = 'A Item' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot delete owner_a''s item'
);

select tests.authenticate_as('owner_a');

-- Owner A can add a modifier option group to their own item.
select lives_ok(
  $$insert into public.menu_item_options (menu_item_id, name, is_required, allow_multiple)
    values ((select id from public.menu_items where name = 'A Item'), 'Velicina', true, false)$$,
  'owner_a can add an option group to their own item'
);

select tests.authenticate_as('owner_b');

-- Owner B cannot add an option group to owner A's item.
select throws_ok(
  $$insert into public.menu_item_options (menu_item_id, name)
    values ((select id from public.menu_items where name = 'A Item'), 'Spoofed Option')$$,
  '42501',
  null,
  'owner_b cannot add an option group to owner_a''s item'
);

-- Owner B cannot update owner A's option group.
select results_eq(
  $$update public.menu_item_options set name = 'Hacked' where name = 'Velicina' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot update owner_a''s option group'
);

-- Owner B cannot delete owner A's option group.
select results_eq(
  $$delete from public.menu_item_options where name = 'Velicina' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot delete owner_a''s option group'
);

select tests.authenticate_as('owner_a');

-- Owner A can add a choice to their own option group.
select lives_ok(
  $$insert into public.menu_item_option_choices (option_id, name, price_delta)
    values ((select id from public.menu_item_options where name = 'Velicina'), 'Velika', 150)$$,
  'owner_a can add a choice to their own option group'
);

select tests.authenticate_as('owner_b');

-- Owner B cannot add a choice to owner A's option group.
select throws_ok(
  $$insert into public.menu_item_option_choices (option_id, name)
    values ((select id from public.menu_item_options where name = 'Velicina'), 'Spoofed Choice')$$,
  '42501',
  null,
  'owner_b cannot add a choice to owner_a''s option group'
);

-- Owner B cannot update owner A's choice.
select results_eq(
  $$update public.menu_item_option_choices set price_delta = 999 where name = 'Velika' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot update owner_a''s choice'
);

-- Owner B cannot delete owner A's choice.
select results_eq(
  $$delete from public.menu_item_option_choices where name = 'Velika' returning 1$$,
  ARRAY[]::integer[],
  'owner_b cannot delete owner_a''s choice'
);

select tests.authenticate_as('owner_a');

-- Owner A can delete their own item (cascades its option groups/choices).
select results_eq(
  $$delete from public.menu_items where name = 'A Item' returning 1$$,
  ARRAY[1],
  'owner_a can delete their own item'
);

-- Owner A can delete their own menu category.
select results_eq(
  $$delete from public.menu_categories where name = 'A Category' returning 1$$,
  ARRAY[1],
  'owner_a can delete their own menu category'
);

select * from finish();
rollback;
