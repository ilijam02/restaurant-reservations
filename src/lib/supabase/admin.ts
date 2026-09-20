import { createClient } from "@supabase/supabase-js";

// The ONLY place the service-role key is used. The key bypasses RLS entirely,
// so it is never exposed as a general-purpose client: this module offers one
// narrow operation, on a user id the caller has already established from the
// signed-in session, and it must only be imported from Server Actions / server
// code (never a Client Component). The key comes from a non-NEXT_PUBLIC
// variable, so it can't be inlined into a browser bundle either.
//
// Why it exists: Supabase Auth's own email change (auth.updateUser({ email }))
// sends confirmation messages, is capped at a few a hour by the built-in
// mailer, and only takes effect once a link is clicked. The app doesn't verify
// emails at signup either, so an email change applies directly instead.

export type AdminUpdateResult =
  | { ok: true }
  // SUPABASE_SERVICE_ROLE_KEY isn't set in this environment.
  | { ok: false; unavailable: true }
  | { ok: false; error: { code?: string; status?: number } };

export async function updateUserEmailAsAdmin(
  userId: string,
  changes: { email: string; password?: string },
): Promise<AdminUpdateResult> {
  if (typeof window !== "undefined") throw new Error("The admin client must never run in the browser.");

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceRoleKey) return { ok: false, unavailable: true };

  const admin = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  // email_confirm marks the new address confirmed, which is what keeps Auth
  // from sending anything. A password, when given, goes in the same call so the
  // two changes are one atomic update.
  const { error } = await admin.auth.admin.updateUserById(userId, {
    email: changes.email,
    email_confirm: true,
    ...(changes.password ? { password: changes.password } : {}),
  });
  return error ? { ok: false, error } : { ok: true };
}
