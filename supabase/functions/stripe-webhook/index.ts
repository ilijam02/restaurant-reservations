import Stripe from "npm:stripe@22.6.2";
import { adminClient, stripeClient } from "../_shared/clients.ts";
import { refundStrayPayment } from "../_shared/refund.ts";

// Stripe calls this, not a signed-in user, so it runs with verify_jwt = false
// (config.toml); the Stripe-Signature header is the authentication. The body
// has to be read as raw text - re-serialized JSON would break the signature.
const cryptoProvider = Stripe.createSubtleCryptoProvider();

Deno.serve(async (req) => {
  const signature = req.headers.get("Stripe-Signature");
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!signature || !secret) return new Response("Bad request", { status: 400 });

  const stripe = stripeClient();
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature, secret, undefined, cryptoProvider);
  } catch (error) {
    console.warn("webhook signature verification failed", error);
    return new Response("Invalid signature", { status: 400 });
  }

  try {
    // async_payment_succeeded is here for completeness (delayed payment
    // methods); card payments arrive as completed with payment_status "paid".
    if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") {
      const session = event.data.object as Stripe.Checkout.Session;
      const orderId = session.metadata?.order_id;

      if (orderId && session.payment_status === "paid") {
        const paymentIntentId = typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id;
        const admin = adminClient();

        // Pay first, book after: this is where the reservation is actually
        // created, in one transaction with marking the order paid.
        const { data: state, error } = await admin.rpc("finalize_paid_booking", {
          p_order_id: orderId,
          p_session_id: session.id,
          p_payment_intent_id: paymentIntentId ?? null,
        });
        // A non-2xx makes Stripe retry, which is what we want for a transient failure.
        if (error) throw error;

        if ((state === "failed" || state === "stray") && paymentIntentId) {
          // Money taken but no reservation: the slot was taken while the customer
          // paid, the cart changed, or nothing is waiting for this payment (a
          // second Checkout session for a booking that already went through).
          // Give it back rather than keep it. Retries of this webhook land here
          // again and refund idempotently.
          console.warn(`refunding payment ${paymentIntentId} for order ${orderId} (${state})`);
          await refundStrayPayment(stripe, paymentIntentId);
        }
      }
    }
  } catch (error) {
    console.error("webhook handling failed", error);
    return new Response("Handler error", { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
});
