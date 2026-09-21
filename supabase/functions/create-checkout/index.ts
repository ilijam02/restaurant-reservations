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

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isUuid = (v: unknown): v is string => typeof v === "string" && UUID.test(v);

type Booking = {
  restaurant_id: string;
  party_size: number;
  starts_at: string;
  stay_minutes: number | null;
  section_id: string | null;
  table_ids: string[] | null;
};

// The booking request the customer wants paid for. Parsed strictly and rebuilt
// field by field, because it is stored on the order and later replayed into
// create_reservation() by the webhook.
function parseBooking(raw: unknown): Booking | null {
  if (typeof raw !== "object" || raw === null) return null;
  const b = raw as Record<string, unknown>;

  const startsAt = typeof b.starts_at === "string" ? new Date(b.starts_at) : null;
  const stay = b.stay_minutes ?? null;
  const section = b.section_id ?? null;
  const tables = b.table_ids ?? null;

  if (
    !isUuid(b.restaurant_id) ||
    !Number.isInteger(b.party_size) ||
    (b.party_size as number) <= 0 ||
    !startsAt ||
    Number.isNaN(startsAt.getTime()) ||
    !(stay === null || (Number.isInteger(stay) && (stay as number) > 0)) ||
    !(section === null || isUuid(section)) ||
    !(tables === null || (Array.isArray(tables) && tables.every(isUuid)))
  ) {
    return null;
  }

  return {
    restaurant_id: b.restaurant_id,
    party_size: b.party_size as number,
    starts_at: startsAt.toISOString(),
    stay_minutes: stay as number | null,
    section_id: section as string | null,
    table_ids: tables as string[] | null,
  };
}

// Pay first, book after: this creates NO reservation. It dry-runs the booking so
// an impossible request is refused before any money moves, opens a Checkout
// Session for the customer's draft order, and stores the booking request on the
// order; the reservation is only created by stripe-webhook once the payment has
// succeeded (finalize_paid_booking), or the payment is refunded if it can't be.
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const caller = await callerClient(req);
    if (!caller) return json({ error: "Niste prijavljeni." }, 401);

    const body = await req.json();
    const booking = parseBooking(body.booking);
    if (!isUuid(body.order_id) || !booking || !allowedOrigins().includes(body.return_origin)) {
      return json({ error: "Neispravan zahtev." }, 400);
    }
    const orderId: string = body.order_id;
    const returnOrigin: string = body.return_origin;

    // Read as the caller, so RLS scopes it; customer_id is checked on top. The
    // amount comes from here, never from the request.
    const { data: order, error: orderError } = await caller.client
      .from("orders")
      .select("id, restaurant_id, payment_status, stripe_checkout_session_id, restaurants(name), order_items(unit_price, quantity)")
      .eq("id", orderId)
      .eq("customer_id", caller.user.id)
      .eq("status", "draft")
      .maybeSingle();

    if (orderError) throw orderError;
    if (!order) return json({ error: "Korpa ne postoji." }, 404);
    if (order.restaurant_id !== booking.restaurant_id) return json({ error: "Neispravan zahtev." }, 400);
    if (order.payment_status !== "unpaid") return json({ error: "Porudžbina je već plaćena." }, 409);

    const items = (order.order_items ?? []) as { unit_price: number; quantity: number }[];
    if (items.length === 0) return json({ error: "Porudžbina je prazna." }, 400);

    const totalPara = orderTotalMinorRsd(items);
    const config = chargeConfigFromEnv((name) => Deno.env.get(name));
    let amount: number;
    try {
      amount = chargeAmountMinor(totalPara, config);
    } catch (error) {
      return json({ error: (error as Error).message }, 400);
    }

    // The dry run: the same rules, and the same readable errors, the real
    // booking will apply (closed, full, table taken, in the past, cart invalid).
    const { error: validationError } = await caller.client.rpc("validate_booking", {
      p_restaurant_id: booking.restaurant_id,
      p_party_size: booking.party_size,
      p_starts_at: booking.starts_at,
      p_stay_minutes: booking.stay_minutes,
      p_section_id: booking.section_id,
      p_table_ids: booking.table_ids,
      p_order_id: orderId,
    });
    if (validationError) {
      // P0001 messages are the booking rules' own user-facing Serbian.
      if (validationError.code === "P0001") return json({ error: validationError.message }, 409);
      throw validationError;
    }

    const stripe = stripeClient();
    const admin = adminClient();

    // A previous attempt left a session behind: if it was actually paid (the
    // webhook may simply not have landed yet) don't charge twice; if it's still
    // open, close it so only one session is payable.
    if (order.stripe_checkout_session_id) {
      try {
        const previous = await stripe.checkout.sessions.retrieve(order.stripe_checkout_session_id);
        if (previous.payment_status === "paid") {
          return json({ error: "Plaćanje je već primljeno - rezervacija se upravo potvrđuje." }, 409);
        }
        if (previous.status === "open") await stripe.checkout.sessions.expire(previous.id);
      } catch (error) {
        // e.g. a session from a since-rotated Stripe key - nothing to clean up.
        console.warn("previous checkout session lookup failed", error);
      }
    }

    const returnBase = `${returnOrigin}/customer/restaurants/${booking.restaurant_id}/reserve`;
    const restaurantName = (order.restaurants as unknown as { name: string } | null)?.name ?? "Restoran";
    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      // "Pay by debit card": without this Stripe offers every method enabled on
      // the account (Bancontact, EPS, ...), some of which complete asynchronously.
      payment_method_types: ["card"],
      // Stripe would otherwise offer the customer their local currency (RSD)
      // with its own 4% conversion fee on top, so the page would show more than
      // the order's total. One fixed price, in the charge currency.
      adaptive_pricing: { enabled: false },
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
      client_reference_id: orderId,
      metadata: { order_id: orderId },
      // Stripe's minimum lifetime is 30 minutes, measured when *it* receives the
      // request - so a few minutes of margin, or latency could put this just
      // under the minimum and fail every checkout. An abandoned session then
      // stops being payable instead of lingering.
      expires_at: Math.floor(Date.now() / 1000) + 35 * 60,
      success_url: `${returnBase}?payment=success&order=${orderId}`,
      cancel_url: `${returnBase}?payment=cancelled&order=${orderId}`,
    });

    const { error: rpcError } = await admin.rpc("set_order_pending_booking", {
      p_order_id: orderId,
      p_session_id: session.id,
      p_booking: booking,
      p_total_para: totalPara,
    });
    if (rpcError) {
      // The order changed under us; don't leave a payable session behind.
      await stripe.checkout.sessions.expire(session.id).catch(() => {});
      return json({ error: rpcError.message }, 409);
    }

    return json({ url: session.url });
  } catch (error) {
    console.error("create-checkout failed", error);
    return json({ error: "Plaćanje trenutno nije dostupno. Pokušajte ponovo." }, 500);
  }
});
