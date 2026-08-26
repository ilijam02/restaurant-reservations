-- One row per auth user, holding the signup fields Supabase Auth itself
-- doesn't store (first/last name, phone, role).
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  first_name text not null,
  last_name text not null,
  phone text not null,
  role text not null check (role in ('customer', 'employee', 'owner')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Explicit grants: this project has "automatically expose new tables"
-- disabled, so nothing is reachable via the Data API until granted here.
-- No insert grant for `authenticated` - rows are created only by the
-- trigger below (as the table owner, bypassing RLS), never directly by
-- end users, so there's no direct-insert path to lock down.
grant select, update on public.profiles to authenticated;

create policy "Users can view their own profile"
  on public.profiles for select
  to authenticated
  using (auth.uid() = id);

create policy "Users can update their own profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Copies first_name/last_name/phone/role out of the signup call's user
-- metadata into a new profiles row whenever a user is created, in the same
-- transaction as the auth.users insert - so a user can never exist without
-- a matching profile, and an invalid/missing role fails the whole signup.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, first_name, last_name, phone, role)
  values (
    new.id,
    new.raw_user_meta_data ->> 'first_name',
    new.raw_user_meta_data ->> 'last_name',
    new.raw_user_meta_data ->> 'phone',
    new.raw_user_meta_data ->> 'role'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
