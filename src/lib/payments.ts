import { FunctionsHttpError } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/client";

// Client side of the payment Edge Functions (supabase/functions/). Stripe is in
// test mode only, and every secret stays in the functions - the browser just
// asks for a Checkout URL and for pending refunds to be carried out.

export type PaymentStatus = "unpaid" | "paid" | "refund_pending" | "refunded";

export const PAYMENT_STATUS_LABELS: Record<PaymentStatus, string> = {
  unpaid: "Nije plaćeno",
  paid: "Plaćeno",
  refund_pending: "Povraćaj novca u toku",
  refunded: "Novac je vraćen",
};

// The functions answer failures with { error: "<Serbian message>" } and a
// non-2xx status, which supabase-js surfaces as a FunctionsHttpError whose
// `context` is the raw Response.
export async function functionErrorMessage(error: unknown, fallback: string): Promise<string> {
  if (error instanceof FunctionsHttpError) {
    try {
      const body = await error.context.json();
      if (typeof body?.error === "string") return body.error;
    } catch {
      // Not JSON - use the fallback.
    }
  }
  return fallback;
}

// What the customer wants booked - sent to Stripe's checkout instead of creating
// the reservation, because a reservation with an order only comes into being once
// its payment has succeeded (see create-checkout / stripe-webhook).
export type BookingRequest = {
  orderId: string;
  restaurantId: string;
  partySize: number;
  startsAt: string;
  stayMinutes: number | null;
  sectionId: string | null;
  tableIds: string[] | null;
};

// Pay first, book after: asks create-checkout to dry-run the booking and open a
// Stripe Checkout Session for the draft order. No reservation is created here;
// the amount is computed by the function from the order, never sent from here.
// A refusal comes back as { error } with the booking rules' own Serbian message.
export async function startCheckout(request: BookingRequest): Promise<{ url: string } | { error: string }> {
  const { data, error } = await createClient().functions.invoke("create-checkout", {
    body: {
      order_id: request.orderId,
      return_origin: window.location.origin,
      booking: {
        restaurant_id: request.restaurantId,
        party_size: request.partySize,
        starts_at: request.startsAt,
        stay_minutes: request.stayMinutes,
        section_id: request.sectionId,
        table_ids: request.tableIds,
      },
    },
  });

  if (error) return { error: await functionErrorMessage(error, "Plaćanje trenutno nije dostupno. Pokušajte ponovo.") };
  if (typeof data?.url !== "string") return { error: "Plaćanje trenutno nije dostupno. Pokušajte ponovo." };
  return { url: data.url };
}

// Carries out every refund the caller is owed or owes ('refund_pending' orders
// they can see). Cancelling only queues the refund in the database; this is what
// sends it to Stripe, and calling it again is the retry for one that failed.
export async function requestRefunds(): Promise<{ refunded: number; failed: number } | { error: string }> {
  const { data, error } = await createClient().functions.invoke("refund-order", { body: {} });

  if (error) return { error: await functionErrorMessage(error, "Povraćaj novca trenutno nije uspeo. Pokušajte ponovo.") };
  return { refunded: data?.refunded ?? 0, failed: data?.failed ?? 0 };
}
