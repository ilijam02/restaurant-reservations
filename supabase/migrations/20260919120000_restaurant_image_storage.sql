-- Owner-uploaded images: a restaurant cover image and menu item photos.
--
-- restaurants.image_url is new; menu_items.image_url already exists (added
-- unused in 20260911091500_create_menu_items.sql). Both hold the full public
-- URL of an object in the bucket below, or null when there's no image (the
-- UI renders an inline SVG placeholder client-side in that case instead of a
-- stored default).
alter table public.restaurants
  add column image_url text;

-- One public bucket for both kinds of image. Public because restaurant and
-- menu photos aren't sensitive and customers browse them constantly - a
-- public bucket serves them straight from the CDN by URL with no per-read
-- signing. The bucket-level limits are a backstop for the client-side
-- resize/validation (see src/lib/image-upload.ts), not the only check.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'restaurant-images',
  'restaurant-images',
  true,
  5242880, -- 5 MiB, after the client has downscaled
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

-- Objects live at "<restaurant_id>/<random>.<ext>", so ownership of an
-- object is ownership of the restaurant named by its first path segment.
-- Compared as text (r.id::text = ...) rather than casting the segment to
-- uuid, since a non-uuid folder name would otherwise raise instead of just
-- failing the policy. Writes are owner-only; reads of the public bucket by
-- URL bypass RLS entirely, so the select policy below exists only because
-- the Storage API needs to see an object to delete it.
create policy "Owners can upload images to their own restaurants"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'restaurant-images'
    and exists (
      select 1 from public.restaurants r
      where r.owner_id = auth.uid()
        and r.id::text = (storage.foldername(name))[1]
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
        and r.id::text = (storage.foldername(name))[1]
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
        and r.id::text = (storage.foldername(name))[1]
    )
  );
