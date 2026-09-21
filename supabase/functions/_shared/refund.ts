import type Stripe from "npm:stripe@22.6.2";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

// Stripe only remembers an idempotency key for about a day. After that, asking
// again for a refund that already happened (a retry after a crash between the
// Stripe call and the database update, or a refund made from the Stripe
// dashboard) is a fresh request and fails with charge_already_refunded - which
// for our purposes means "done", not "failed".
async function createRefund(stripe: Stripe, paymentIntentId: string, idempotencyKey: string): Promise<void> {
  try {
    await stripe.refunds.create({ payment_intent: paymentIntentId }, { idempotencyKey });
  } catch (error) {
    if ((error as { code?: string }).code === "charge_already_refunded") return;
    throw error;
  }
}

// Refund one order that cancel_reservation() (or mark_order_paid(), for a
// payment that landed after a cancellation) already put in 'refund_pending'.
// The idempotency key makes a quick retry return the same refund instead of a
// second one; it's keyed by order because an order is refunded at most once.
export async function refundOrder(
  stripe: Stripe,
  admin: SupabaseClient,
  orderId: string,
  paymentIntentId: string,
): Promise<void> {
  await createRefund(stripe, paymentIntentId, `refund-order-${orderId}`);

  const { error } = await admin.rpc("mark_order_refunded", { p_order_id: orderId });
  if (error) throw new Error(`mark_order_refunded failed: ${error.message}`);
}

// Refund a payment that has no order to be attached to: a second payment for an
// order that was already paid ('duplicate' from mark_order_paid), or one for an
// order that doesn't exist. Nothing to record in the database - the money simply
// goes back.
export async function refundStrayPayment(stripe: Stripe, paymentIntentId: string): Promise<void> {
  await createRefund(stripe, paymentIntentId, `refund-stray-${paymentIntentId}`);
}
