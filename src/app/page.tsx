import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { ROLE_HOME_PATH } from "@/lib/auth/redirect";
import { getProfileRole } from "@/lib/auth/role";

// The proxy already redirects every request to "/" away from this page, so
// this is a safety-net fallback, not the primary redirect path.
export default async function RootPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const role = user ? await getProfileRole(supabase, user.id) : null;

  redirect(role ? ROLE_HOME_PATH[role] : "/login");
}
