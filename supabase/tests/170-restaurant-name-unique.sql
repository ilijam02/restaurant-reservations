-- Coverage for supabase/migrations/20260920110000_restaurant_name_unique.sql:
-- restaurant names are unique among live (non-archived) restaurants across all
-- owners, compared after normalization (normalize_restaurant_name(): case,
-- any whitespace, invisible characters, Unicode forms, Serbian Cyrillic).
--
-- owner_s and owner_t are two different owners, so the rule is app-wide and not
-- per owner. The name-freed-by-archiving case archives directly with the
-- service role (only the flag matters here; delete_restaurant() is covered in
-- 140-delete-restaurant.sql).
begin;
select plan(17);

select tests.create_supabase_user('owner_s', 'owners@test.com', null,
  '{"first_name":"Owner","last_name":"S","phone":"555-0061","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_t', 'ownert@test.com', null,
  '{"first_name":"Owner","last_name":"T","phone":"555-0062","role":"owner"}'::jsonb);

select is(
  (select count(*) from pg_indexes
   where schemaname = 'public' and tablename = 'restaurants'
     and indexname = 'restaurants_live_name_unique_idx'),
  1::bigint,
  'the unique index on live restaurant names exists'
);

-- === Duplicates are refused, whoever owns them ===
select tests.authenticate_as('owner_s');
select lives_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_s'), 'Jedinstveni Restoran')$$,
  'owner_s creates a restaurant'
);

select tests.authenticate_as('owner_t');
-- The message names the index: the create and edit forms tell this violation
-- apart from any other 23505 by exactly that string.
select throws_like(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_t'), 'Jedinstveni Restoran')$$,
  '%restaurants_live_name_unique_idx%',
  'a different owner cannot reuse the same name, and the error names the index'
);
select throws_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_t'), 'JEDINSTVENI RESTORAN')$$,
  '23505',
  null,
  'a name differing only in case is the same name'
);
select throws_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_t'), '  jedinstveni restoran ')$$,
  '23505',
  null,
  'so is one differing only in surrounding whitespace'
);
select throws_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_t'), 'Jedinstveni  Restoran')$$,
  '23505',
  null,
  'a doubled space inside the name does not make it a different name'
);
select throws_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_t'), 'Jedinstveni' || chr(9) || 'Restoran')$$,
  '23505',
  null,
  'nor does a tab'
);
select throws_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_t'), 'Jedinstveni' || chr(160) || 'Restoran')$$,
  '23505',
  null,
  'nor does a non-breaking space'
);
select throws_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_t'), 'Jedinstveni Restoran' || chr(8203))$$,
  '23505',
  null,
  'nor does an invisible zero-width character at the end'
);
select throws_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_t'), 'Јединствени Ресторан')$$,
  '23505',
  null,
  'nor does the same name written in Serbian Cyrillic'
);
select lives_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_t'), 'Drugi Restoran')$$,
  'a genuinely different name is fine'
);

-- === Renaming is held to the same rule ===
select throws_ok(
  $$update public.restaurants set name = 'jedinstveni restoran' where name = 'Drugi Restoran'$$,
  '23505',
  null,
  'renaming a restaurant to another live restaurant''s name is refused'
);

select tests.authenticate_as('owner_s');
select lives_ok(
  $$update public.restaurants set name = 'JEDINSTVENI RESTORAN' where name = 'Jedinstveni Restoran'$$,
  'an owner can change the capitalisation of their own restaurant''s name (it does not collide with itself)'
);

-- === An archived restaurant gives its name back ===
reset role;  -- fixture step as the superuser: works whether or not service_role has table grants
update public.restaurants set archived_at = now() where name = 'JEDINSTVENI RESTORAN';

select tests.authenticate_as('owner_t');
select lives_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_t'), 'Jedinstveni Restoran')$$,
  'once the restaurant is archived, its name can be used again'
);

-- ...and the rule still holds for the new, live holder of the name.
select tests.authenticate_as('owner_s');
select throws_ok(
  $$insert into public.restaurants (owner_id, name)
    values (tests.get_supabase_uid('owner_s'), 'jedinstveni restoran')$$,
  '23505',
  null,
  'the archived row did not replace the rule: the new live holder still blocks duplicates'
);

-- === The normalization itself ===
select is(
  public.normalize_restaurant_name('Ђурђевак Љубичица ЊЕГОШ Џем'),
  'đurđevak ljubičica njegoš džem',
  'Serbian Cyrillic is transliterated to Latin, including the digraph letters (љ, њ, џ) and ђ'
);
select isnt(
  public.normalize_restaurant_name('Šumadija'),
  public.normalize_restaurant_name('Sumadija'),
  'diacritics are kept: names that differ in a č, ć, š, ž or đ are different names'
);

select * from finish();
rollback;
