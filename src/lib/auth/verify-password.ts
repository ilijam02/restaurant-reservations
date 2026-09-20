import { createClient, type SupabaseClient } from "@supabase/supabase-js";

// Re-checks a user's password on a throwaway client that keeps no session, so
// it can't rotate the real session's cookies. Returns that client, signed in
// (a brand-new session, which also satisfies Supabase's "recently signed in"
// rule for password/email changes - the cookie session may be months old), or
// null when the password is wrong. Callers must hand it to releaseVerifier()
// when done.
//
// Used for the "type your password to confirm" steps (deleting the account,
// changing email/phone/password). It is a guard against a misclick or an
// unattended browser, not a security boundary: the database functions and
// table grants behind these actions stay callable by the signed-in user.
export async function verifyPassword(email: string, password: string): Promise<SupabaseClient | null> {
  const client = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { error } = await client.auth.signInWithPassword({ email, password });
  return error ? null : client;
}

// Only this throwaway session: the default (global) scope would sign the user
// out everywhere.
export async function releaseVerifier(client: SupabaseClient): Promise<void> {
  await client.auth.signOut({ scope: "local" }).catch(() => {});
}
