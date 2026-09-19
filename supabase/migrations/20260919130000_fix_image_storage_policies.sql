-- Fixes the three restaurant-images policies from
-- 20260919120000_restaurant_image_storage.sql, which denied every write.
--
-- Inside their `exists (select 1 from public.restaurants r ...)` subquery, the
-- unqualified `name` in `storage.foldername(name)` resolved to r.name (the
-- restaurant's own name column - the nearest scope) instead of the storage
-- object's path, so the folder never matched a restaurant id. Qualifying it
-- as objects.name points it at the object being written.
drop policy "Owners can upload images to their own restaurants" on storage.objects;
drop policy "Owners can view their own restaurants' images" on storage.objects;
drop policy "Owners can delete their own restaurants' images" on storage.objects;

create policy "Owners can upload images to their own restaurants"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'restaurant-images'
    and exists (
      select 1 from public.restaurants r
      where r.owner_id = auth.uid()
        and r.id::text = (storage.foldername(objects.name))[1]
    )
  );

create policy "Owners can view their own restaurants' images"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'restaurant-images'
    and exists (
      select 1 from public.restaurants r
      where r.owner_id = auth.uid()
        and r.id::text = (storage.foldername(objects.name))[1]
    )
  );

create policy "Owners can delete their own restaurants' images"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'restaurant-images'
    and exists (
      select 1 from public.restaurants r
      where r.owner_id = auth.uid()
        and r.id::text = (storage.foldername(objects.name))[1]
    )
  );
