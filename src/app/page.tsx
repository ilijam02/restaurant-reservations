import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { ROLE_HOME_PATH, type Role } from "@/lib/auth/redirect";

// Middleware already redirects every request to "/" away from this page, so
// this is a safety-net fallback, not the primary redirect path.
export default async function RootPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const role = user?.user_metadata?.role as Role | undefined;

  redirect(role ? ROLE_HOME_PATH[role] : "/login");
}
