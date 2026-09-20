import Stripe from "npm:stripe@^22";
import { createClient } from "npm:@supabase/supabase-js@2";

// STRIPE_SECRET_KEY must be a *test* key (sk_test_...): this app only ever
// moves test money. It's a Supabase secret, never a NEXT_PUBLIC_* variable.
export function stripeClient(): Stripe {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) throw new Error("STRIPE_SECRET_KEY is not set");
  // The fetch client is what works in the Edge runtime (no Node http).
  return new Stripe(key, { httpClient: Stripe.createFetchHttpClient() });
}

// Bypasses RLS - only for the payment-state functions, which are granted to
// service_role alone (see 20260920160000_order_payments.sql).
export function adminClient() {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
}

// A client acting as the caller, so RLS decides what they can see. The
// functions run with verify_jwt = false (config.toml) and validate the token
// here with getUser() instead, which works with either JWT signing-key setup.
export async function callerClient(req: Request) {
  const authorization = req.headers.get("Authorization");
  if (!authorization) return null;

  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
  });
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) return null;
  return { client, user: data.user };
}
