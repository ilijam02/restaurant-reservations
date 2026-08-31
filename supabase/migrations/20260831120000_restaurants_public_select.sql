-- Customers and employees both need to browse the full restaurant list, not
-- just owners viewing their own. Replace the owner-only select policy with a
-- broader one: any authenticated user (any role) can view all restaurants.
-- This makes the owner-only policy redundant (it was a strict subset), so
-- it's dropped rather than left alongside the new one.
drop policy "Owners can view their own restaurants" on public.restaurants;

create policy "Authenticated users can view all restaurants"
  on public.restaurants for select
  to authenticated
  using (true);
