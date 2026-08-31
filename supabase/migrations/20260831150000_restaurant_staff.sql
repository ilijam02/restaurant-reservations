-- Employee applications + staff membership. One row per (restaurant,
-- employee) pair: 'pending' while the employee's application is awaiting
-- the owner's decision, 'accepted' once the owner approves it (i.e. the
-- employee actually works there). There's no 'rejected' status - a reject
-- (by the owner) and a cancel (by the employee) both just delete the pending
-- row, and removing an employee deletes the accepted row. Nothing in the
-- product needs a record of past rejections/removals, and deleting keeps
-- the door open to re-apply later without extra status-transition logic.
-- An employee can work at multiple restaurants (many rows, one per
-- restaurant), but only one relationship per (restaurant, employee) pair
-- at a time.
create table public.restaurant_staff (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants (id) on delete cascade,
  employee_id uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  unique (restaurant_id, employee_id)
);

create index restaurant_staff_employee_id_idx on public.restaurant_staff (employee_id);

alter table public.restaurant_staff enable row level security;

-- Explicit grants: this project has "automatically expose new tables"
-- disabled, so nothing is reachable via the Data API until granted here.
grant select, insert, update, delete on public.restaurant_staff to authenticated;

create policy "Employees can view their own applications"
  on public.restaurant_staff for select
  to authenticated
  using (employee_id = auth.uid());

create policy "Owners can view applications to their restaurants"
  on public.restaurant_staff for select
  to authenticated
  using (
    exists (
      select 1 from public.restaurants
      where id = restaurant_id and owner_id = auth.uid()
    )
  );

-- Application creation is further restricted to accounts with
-- role = 'employee' (matching the restaurants table's owner-role check),
-- and always starts 'pending' - only the owner-only update policy below can
-- move a row to 'accepted'.
create policy "Employee-role accounts can apply to restaurants"
  on public.restaurant_staff for insert
  to authenticated
  with check (
    employee_id = auth.uid()
    and status = 'pending'
    and exists (
      select 1 from public.profiles
      where id = auth.uid() and role = 'employee'
    )
  );

-- The only allowed update is an owner accepting a pending application for
-- their own restaurant. Kept as the sole update policy (rather than also
-- giving employees an update policy) so the usual "multiple permissive
-- policies OR their USING and WITH CHECK separately" behavior can't combine
-- an owner's USING clause with an employee's WITH CHECK clause or vice
-- versa.
create policy "Owners can accept pending applications for their restaurants"
  on public.restaurant_staff for update
  to authenticated
  using (
    status = 'pending'
    and exists (
      select 1 from public.restaurants
      where id = restaurant_id and owner_id = auth.uid()
    )
  )
  with check (
    status = 'accepted'
    and exists (
      select 1 from public.restaurants
      where id = restaurant_id and owner_id = auth.uid()
    )
  );

-- Employees can only cancel while still pending - once accepted, ending the
-- relationship is the owner's call (the "remove" action below).
create policy "Employees can cancel their own pending applications"
  on public.restaurant_staff for delete
  to authenticated
  using (employee_id = auth.uid() and status = 'pending');

-- Covers both owner actions: rejecting a pending application and removing
-- an accepted staff member - both are just "delete the row" from the
-- owner's side.
create policy "Owners can reject or remove staff at their restaurants"
  on public.restaurant_staff for delete
  to authenticated
  using (
    exists (
      select 1 from public.restaurants
      where id = restaurant_id and owner_id = auth.uid()
    )
  );

-- Owners need applicant/employee names to show a usable staff list, but the
-- existing profiles policy only lets a user view their own profile. Add a
-- narrow extra policy: an owner can view the profile of anyone who has a
-- restaurant_staff row (pending or accepted) at one of their restaurants.
create policy "Owners can view profiles of their restaurants' staff/applicants"
  on public.profiles for select
  to authenticated
  using (
    exists (
      select 1 from public.restaurant_staff rs
      join public.restaurants r on r.id = rs.restaurant_id
      where rs.employee_id = profiles.id and r.owner_id = auth.uid()
    )
  );
