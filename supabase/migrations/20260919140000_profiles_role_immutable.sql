-- profiles.role is what every RLS policy and RPC in the app authorizes on
-- (restaurant creation needs 'owner', applying to a restaurant needs
-- 'employee', reserving/ordering needs 'customer') and what the proxy routes
-- on. But the original grant was a table-wide `update` with an own-row
-- policy, so any signed-in user could run
--   update profiles set role = 'owner' where id = auth.uid()
-- and become any role - creating restaurants, reading their customers'
-- profiles, etc. Nothing in the app updates profiles at all today.
--
-- Column-level grant instead: a user can still edit the fields that are
-- theirs to edit, but not `role` (or `id`/`created_at`). The role is set
-- exactly once, by handle_new_user() at signup (a security definer trigger,
-- unaffected by this grant).
revoke update on public.profiles from authenticated;
grant update (first_name, last_name, phone) on public.profiles to authenticated;
