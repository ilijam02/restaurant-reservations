import type { SupabaseClient } from "@supabase/supabase-js";
import type { Role } from "@/lib/auth/redirect";

const ROLES: readonly string[] = ["customer", "employee", "owner"];

// The signed-in user's role, read from `profiles.role` - the same value every
// RLS policy and RPC checks. Deliberately NOT `user.user_metadata.role`: that
// is user-editable (`supabase.auth.updateUser({ data: { role } })`), so
// routing on it would let anyone open another role's pages just by changing
// it. `profiles.role` can't be written by the user (see
// 20260919140000_profiles_role_immutable.sql).
//
// Returns null when there's no profile row or the query fails, so callers
// fail closed (treated as signed-out) rather than falling back to a weaker
// source. A failed query is logged: otherwise a grant/RLS regression on
// `profiles` would make every user look signed out with nothing to go on.
export async function getProfileRole(supabase: SupabaseClient, userId: string): Promise<Role | null> {
  const { data, error } = await supabase.from("profiles").select("role").eq("id", userId).maybeSingle();
  if (error) {
    console.error("getProfileRole: profiles lookup failed", error.message);
    return null;
  }
  const role = data?.role;
  return typeof role === "string" && ROLES.includes(role) ? (role as Role) : null;
}
