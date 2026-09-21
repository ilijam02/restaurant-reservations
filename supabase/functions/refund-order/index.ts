import { adminClient, callerClient, stripeClient } from "../_shared/clients.ts";
import { corsHeaders, json } from "../_shared/http.ts";
import { refundOrder } from "../_shared/refund.ts";

// Refunds every order the caller can see that is waiting for one
// ('refund_pending'). The decision that an order gets its money back was
// already made by cancel_reservation() in the database; this only carries it
// out, so it takes no order id from the client - and being idempotent and
// argument-free also makes it the retry for a refund that failed, and the
// follow-up to an owner's "cancel all reservations". RLS scopes the read: a
// customer sees their own orders, an owner the orders at their restaurants.
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const caller = await callerClient(req);
    if (!caller) return json({ error: "Niste prijavljeni." }, 401);

    const { data: orders, error } = await caller.client
      .from("orders")
      .select("id, stripe_payment_intent_id")
      .eq("payment_status", "refund_pending")
      .limit(50);
    if (error) throw error;

    const stripe = stripeClient();
    const admin = adminClient();
    let refunded = 0;
    let failed = 0;

    for (const order of orders ?? []) {
      if (!order.stripe_payment_intent_id) {
        failed++;
        continue;
      }
      try {
        await refundOrder(stripe, admin, order.id, order.stripe_payment_intent_id);
        refunded++;
      } catch (refundError) {
        console.error(`refund of order ${order.id} failed`, refundError);
        failed++;
      }
    }

    return json({ refunded, failed });
  } catch (error) {
    console.error("refund-order failed", error);
    return json({ error: "Povraćaj novca trenutno nije uspeo. Pokušajte ponovo." }, 500);
  }
});
