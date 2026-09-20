import type Stripe from "npm:stripe@^22";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

// Refund one order that cancel_reservation() (or mark_order_paid(), for a
// payment that landed after a cancellation) already put in 'refund_pending'.
// The idempotency key makes a retry - after a crash between the Stripe call
// and the database update, say - return the same refund instead of a second
// one; it's keyed by order because an order is refunded at most once.
export async function refundOrder(
  stripe: Stripe,
  admin: SupabaseClient,
  orderId: string,
  paymentIntentId: string,
): Promise<void> {
  await stripe.refunds.create(
    { payment_intent: paymentIntentId, metadata: { order_id: orderId } },
    { idempotencyKey: `refund-order-${orderId}` },
  );

  const { error } = await admin.rpc("mark_order_refunded", { p_order_id: orderId });
  if (error) throw new Error(`mark_order_refunded failed: ${error.message}`);
}
