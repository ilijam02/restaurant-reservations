-- The "owners can view their staff's profiles" policy (previous migration)
-- creates a policy cycle: restaurant_staff's insert policy queries
-- profiles, and profiles' select policy queries restaurant_staff. Postgres
-- detects that as infinite recursion at plan time (42P17), even though the
-- actual data wouldn't recurse - inserting into restaurant_staff fails
-- outright. Fix: move the restaurant_staff lookup into a security-definer
-- function, same pattern as handle_new_user - it runs with the function
-- owner's privileges (bypassing RLS on restaurant_staff), so evaluating the
-- profiles policy no longer re-enters restaurant_staff's RLS and the cycle
-- is broken.
drop policy "Owners can view profiles of their restaurants' staff/applicants" on public.profiles;

create function public.is_restaurant_owner_of_employee(employee uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.restaurant_staff rs
    join public.restaurants r on r.id = rs.restaurant_id
    where rs.employee_id = employee and r.owner_id = auth.uid()
  );
$$;

grant execute on function public.is_restaurant_owner_of_employee(uuid) to authenticated;

create policy "Owners can view profiles of their restaurants' staff/applicants"
  on public.profiles for select
  to authenticated
  using (public.is_restaurant_owner_of_employee(profiles.id));
