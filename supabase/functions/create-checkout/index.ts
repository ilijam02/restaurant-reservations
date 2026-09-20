import { adminClient, callerClient, stripeClient } from "../_shared/clients.ts";
import { corsHeaders, json } from "../_shared/http.ts";
import { chargeAmountMinor, chargeConfigFromEnv, orderTotalMinorRsd } from "../_shared/payment-amount.ts";

// Where Stripe may send the customer back to. The dev setup signs each role in
// on its own hostname (see CLAUDE.md), and the session cookie is per host, so
// the return URL has to keep whichever host the customer started from - but an
// arbitrary client-supplied origin would make this an open redirect, hence the
// allowlist. Set SITE_URLS (comma-separated) on deployment.
const DEFAULT_SITE_URLS = "http://localhost:3000,http://customer.localhost:3000,http://employee.localhost:3000";

function allowedOrigins(): string[] {
  return (Deno.env.get("SITE_URLS") ?? DEFAULT_SITE_URLS).split(",").map((s) => s.trim());
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const caller = await callerClient(req);
    if (!caller) return json({ error: "Niste prijavljeni." }, 401);

    const { reservation_id: reservationId, return_origin: returnOrigin, return_to: returnTo } = await req.json();
    if (
      typeof reservationId !== "string" ||
      !allowedOrigins().includes(returnOrigin) ||
      (returnTo !== "reserve" && returnTo !== "reservations")
    ) {
      return json({ error: "Neispravan zahtev." }, 400);
    }

    // Read as the caller, so RLS scopes it; customer_id is checked on top
    // because owners and staff can see orders too, but only the customer pays.
    // The amount comes from here, never from the request.
    const { data: order, error: orderError } = await caller.client
      .from("orders")
      .select(
        "id, restaurant_id, payment_status, stripe_checkout_session_id, restaurants(name), reservations(status, ends_at), order_items(unit_price, quantity)",
      )
      .eq("reservation_id", reservationId)
      .eq("customer_id", caller.user.id)
      .eq("status", "confirmed")
      .limit(1)
      .maybeSingle();

    if (orderError) throw orderError;
    if (!order) return json({ error: "Porudžbina ne postoji." }, 404);
    if (order.payment_status !== "unpaid") return json({ error: "Porudžbina je već plaćena." }, 409);

    // Payable only while the reservation can still be cancelled (the states
    // cancel_reservation() accepts): money paid on a no-show / completed /
    // expired reservation could never be refunded. The UI already hides the
    // button; this is the server's own rule.
    const reservation = order.reservations as unknown as { status: string; ends_at: string } | null;
    if (
      !reservation ||
      !["confirmed", "preparing_order", "order_prepared"].includes(reservation.status) ||
      new Date(reservation.ends_at).getTime() <= Date.now()
    ) {
      return json({ error: "Rezervacija više nije aktivna, pa se porudžbina ne može platiti." }, 409);
    }

    const items = (order.order_items ?? []) as { unit_price: number; quantity: number }[];
    if (items.length === 0) return json({ error: "Porudžbina je prazna." }, 400);

    const config = chargeConfigFromEnv((name) => Deno.env.get(name));
    let amount: number;
    try {
      amount = chargeAmountMinor(orderTotalMinorRsd(items), config);
    } catch (error) {
      return json({ error: (error as Error).message }, 400);
    }

    const stripe = stripeClient();
    const admin = adminClient();

    // A previous attempt left a session behind: if it was actually paid (the
    // webhook may simply not have landed yet) record that instead of charging
    // twice; if it's still open, close it so only one session can be paid.
    if (order.stripe_checkout_session_id) {
      try {
        const previous = await stripe.checkout.sessions.retrieve(order.stripe_checkout_session_id);
        if (previous.payment_status === "paid") {
          const paymentIntent = typeof previous.payment_intent === "string" ? previous.payment_intent : previous.payment_intent?.id;
          await admin.rpc("mark_order_paid", {
            p_order_id: order.id,
            p_session_id: previous.id,
            p_payment_intent_id: paymentIntent ?? null,
          });
          return json({ error: "Porudžbina je već plaćena." }, 409);
        }
        if (previous.status === "open") await stripe.checkout.sessions.expire(previous.id);
      } catch (error) {
        // e.g. a session from a since-rotated Stripe key - nothing to clean up.
        console.warn("previous checkout session lookup failed", error);
      }
    }

    // Right after booking, the customer is sent back to that restaurant's
    // reservation page (where they were, as when there's no order); paying an
    // older order from "Moje rezervacije" returns there instead.
    const returnPath =
      returnTo === "reserve" ? `/customer/restaurants/${order.restaurant_id}/reserve` : "/customer/reservations";
    const returnQuery = returnTo === "reserve" ? `&reservation=${reservationId}` : "";

    const restaurantName = (order.restaurants as unknown as { name: string } | null)?.name ?? "Restoran";
    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      // "Pay by debit card": without this Stripe offers every method enabled on
      // the account (Bancontact, EPS, ...), some of which complete asynchronously.
      payment_method_types: ["card"],
      line_items: [
        {
          quantity: 1,
          price_data: {
            currency: config.currency,
            unit_amount: amount,
            product_data: { name: `Porudžbina - ${restaurantName}` },
          },
        },
      ],
      // Stripe would otherwise offer the customer their local currency (RSD)
      // with its own 4% conversion fee on top, so the page would show more than
      // the order's total. One fixed price, in the charge currency.
      adaptive_pricing: { enabled: false },
      client_reference_id: order.id,
      metadata: { order_id: order.id, reservation_id: reservationId },
      // Stripe's minimum lifetime is 30 minutes, measured when *it* receives the
      // request - so a few minutes of margin, or latency could put this just
      // under the minimum and fail every checkout. An abandoned session then
      // stops being payable instead of lingering.
      expires_at: Math.floor(Date.now() / 1000) + 35 * 60,
      success_url: `${returnOrigin}${returnPath}?payment=success${returnQuery}`,
      cancel_url: `${returnOrigin}${returnPath}?payment=cancelled${returnQuery}`,
    });

    const { error: rpcError } = await admin.rpc("set_order_checkout_session", {
      p_order_id: order.id,
      p_session_id: session.id,
    });
    if (rpcError) {
      // The order changed under us (cancelled meanwhile); don't leave a payable session.
      await stripe.checkout.sessions.expire(session.id).catch(() => {});
      return json({ error: rpcError.message }, 409);
    }

    return json({ url: session.url });
  } catch (error) {
    console.error("create-checkout failed", error);
    return json({ error: "Plaćanje trenutno nije dostupno. Pokušajte ponovo." }, 500);
  }
});
