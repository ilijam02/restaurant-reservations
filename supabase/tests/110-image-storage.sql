-- Storage policy coverage for the public 'restaurant-images' bucket (see
-- supabase/migrations/20260919120000_restaurant_image_storage.sql).
--
-- Objects live at "<restaurant_id>/<file>", and write access is ownership of
-- the restaurant named by that first path segment - so the interesting cases
-- are another owner, a customer, and a folder that isn't a restaurant id at
-- all. Reads of the public bucket by URL bypass RLS (not testable here); the
-- select policy is what lets the Storage API find an object to delete.
begin;
select plan(11);

select tests.create_supabase_user('owner_a', 'ownera@test.com', null,
  '{"first_name":"Owner","last_name":"A","phone":"555-0001","role":"owner"}'::jsonb);
select tests.create_supabase_user('owner_b', 'ownerb@test.com', null,
  '{"first_name":"Owner","last_name":"B","phone":"555-0002","role":"owner"}'::jsonb);
select tests.create_supabase_user('customer_a', 'customera@test.com', null,
  '{"first_name":"Customer","last_name":"A","phone":"555-0003","role":"customer"}'::jsonb);

-- Setup (not asserted): each owner has their own restaurant.
select tests.authenticate_as('owner_a');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_a'), 'Slike A');

select tests.authenticate_as('owner_b');
insert into public.restaurants (owner_id, name) values (tests.get_supabase_uid('owner_b'), 'Slike B');

select tests.clear_authentication();
select is(
  (select public from storage.buckets where id = 'restaurant-images'),
  true,
  'the restaurant-images bucket exists and is public'
);

-- === Upload (insert) ===
select tests.authenticate_as('owner_a');
select lives_ok(
  $$insert into storage.objects (bucket_id, name, owner_id)
    values (
      'restaurant-images',
      (select id from public.restaurants where name = 'Slike A')::text || '/cover.webp',
      tests.get_supabase_uid('owner_a')::text
    )$$,
  'owner_a can upload into their own restaurant''s folder'
);

select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id)
    values (
      'restaurant-images',
      (select id from public.restaurants where name = 'Slike B')::text || '/spoofed.webp',
      tests.get_supabase_uid('owner_a')::text
    )$$,
  '42501',
  null,
  'owner_a cannot upload into owner_b''s restaurant folder'
);

select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id)
    values ('restaurant-images', 'not-a-restaurant-id/x.webp', tests.get_supabase_uid('owner_a')::text)$$,
  '42501',
  null,
  'owner_a cannot upload into a folder that is not a restaurant id'
);

select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id)
    values (
      'restaurant-images',
      'x.webp',
      tests.get_supabase_uid('owner_a')::text
    )$$,
  '42501',
  null,
  'owner_a cannot upload to the bucket root (no restaurant folder)'
);

select tests.authenticate_as('customer_a');
select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id)
    values (
      'restaurant-images',
      (select id from public.restaurants where name = 'Slike A')::text || '/customer.webp',
      tests.get_supabase_uid('customer_a')::text
    )$$,
  '42501',
  null,
  'a customer cannot upload into any restaurant''s folder'
);

-- === Visibility (select) ===
select tests.authenticate_as('owner_a');
select is(
  (select count(*) from storage.objects where bucket_id = 'restaurant-images'),
  1::bigint,
  'owner_a can see their own restaurant''s object'
);

select tests.authenticate_as('owner_b');
select is(
  (select count(*) from storage.objects where bucket_id = 'restaurant-images'),
  0::bigint,
  'owner_b cannot see owner_a''s object through the Storage API'
);

-- === Update (no policy exists, so an object can't be moved between folders) ===
select tests.authenticate_as('owner_a');
update storage.objects
  set name = (select id from public.restaurants where name = 'Slike B')::text || '/moved.webp'
  where bucket_id = 'restaurant-images';
select is(
  (select count(*) from storage.objects
   where bucket_id = 'restaurant-images' and name like '%/moved.webp'),
  0::bigint,
  'owner_a cannot move their object into owner_b''s folder (no update policy)'
);

-- === Delete ===
select tests.authenticate_as('owner_b');
delete from storage.objects where bucket_id = 'restaurant-images';

select tests.authenticate_as('owner_a');
select is(
  (select count(*) from storage.objects where bucket_id = 'restaurant-images'),
  1::bigint,
  'owner_b''s delete did not remove owner_a''s object'
);

delete from storage.objects where bucket_id = 'restaurant-images';
select is(
  (select count(*) from storage.objects where bucket_id = 'restaurant-images'),
  0::bigint,
  'owner_a can delete their own restaurant''s object'
);

select * from finish();
rollback;
