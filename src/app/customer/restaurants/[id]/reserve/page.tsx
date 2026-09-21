import { notFound } from "next/navigation";
import { AppHeader } from "@/components/app-header";
import type { PaymentReturn } from "@/components/payment-return-banner";
import { ReservationForm } from "@/components/reservation-form";
import type { CartItem } from "@/components/cart-summary";
import { createClient } from "@/lib/supabase/server";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Explicit timeZone, as everywhere else reservation times are shown: it's the
// restaurant's local time, whatever timezone the server runs in.
function formatReservationTime(iso: string) {
  const date = new Date(iso);
  const day = date.toLocaleDateString("sr-RS", { timeZone: "Europe/Belgrade" });
  const time = date.toLocaleTimeString("sr-RS", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Belgrade" });
  return `${day} u ${time}`;
}

export default async function ReserveRestaurantPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ payment?: string; order?: string }>;
}) {
  const { id } = await params;
  const { payment, order: returnedOrderId } = await searchParams;
  const supabase = await createClient();

  const { data: restaurant } = await supabase
    .from("restaurants")
    .select("id, name, capacity, default_stay_minutes")
    .eq("id", id)
    .is("archived_at", null)
    .single();

  if (!restaurant) {
    notFound();
  }

  const { data: hours } = await supabase
    .from("restaurant_hours")
    .select("day_of_week, start_minute, end_minute")
    .eq("restaurant_id", id)
    .order("day_of_week");

  const { data: sections } = await supabase
    .from("sections")
    .select("id, name, color_index")
    .eq("restaurant_id", id)
    .order("name");

  const { data: layouts } = await supabase
    .from("layouts")
    .select("id, name")
    .eq("restaurant_id", id)
    .eq("is_active", true)
    .order("name");

  // Only tables on a currently-active layout are actually bookable -
  // create_reservation() enforces the same rule server-side.
  const { data: tables } = await supabase
    .from("tables")
    .select("id, name, seats, section_id, layout_id, x, y, width, height, layouts!inner(is_active)")
    .eq("restaurant_id", id)
    .eq("layouts.is_active", true)
    .order("name");

  // At most one row (RLS restricts orders to the caller's own regardless of
  // status, and a customer has at most one 'draft' at a time - see
  // start_cart()). Only treated as this page's cart if it's actually a draft
  // for *this* restaurant - a draft left over from browsing a different
  // restaurant's menu means "no cart here", not an error, matching the menu
  // page's own cross-restaurant handling.
  const { data: draftOrder } = await supabase
    .from("orders")
    .select(
      "id, restaurant_id, items:order_items(id, item_name, unit_price, quantity, choices:order_item_choices(option_name, choice_name, price_delta))",
    )
    .eq("status", "draft")
    .eq("restaurant_id", id)
    .maybeSingle();

  // Stripe sends the customer back here (create-checkout's success/cancel URL)
  // after they paid for - or backed out of paying for - the booking they asked
  // for. The reservation exists only if the payment webhook has already created
  // it, so what to say comes from the order's actual state, looked up under RLS
  // (the caller's own orders only) rather than trusted from the URL:
  //   confirmed        -> booked and paid
  //   draft + failure  -> paid, but the booking couldn't be made (refunded)
  //   draft + pending  -> paid, the webhook hasn't finished yet (the banner polls)
  //   otherwise, if the customer backed out -> nothing was booked
  let paymentReturn: PaymentReturn | null = null;
  if ((payment === "success" || payment === "cancelled") && returnedOrderId && UUID_PATTERN.test(returnedOrderId)) {
    const { data: returned } = await supabase
      .from("orders")
      .select("status, booking_failure, pending_booking, reservations(starts_at)")
      .eq("id", returnedOrderId)
      .eq("restaurant_id", id)
      .maybeSingle();

    if (returned) {
      const reservation = returned.reservations as unknown as { starts_at: string } | null;
      if (returned.status === "confirmed" && reservation) {
        paymentReturn = {
          kind: "success",
          text: `Potvrđeno: rezervacija za ${formatReservationTime(reservation.starts_at)}. Hvala! Plaćanje je primljeno.`,
        };
      } else if (returned.booking_failure) {
        paymentReturn = {
          kind: "error",
          text: `Rezervacija nije napravljena: ${returned.booking_failure} Novac će biti vraćen na karticu.`,
        };
      } else if (payment === "success" && returned.pending_booking) {
        paymentReturn = {
          kind: "processing",
          text: "Plaćanje je primljeno. Rezervacija se upravo potvrđuje...",
        };
      } else if (payment === "cancelled") {
        paymentReturn = {
          kind: "info",
          text: "Plaćanje je otkazano - rezervacija nije napravljena.",
        };
      }
    }
  }

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref={`/customer/restaurants/${id}`} />
      <h1 className="text-3xl font-bold">{restaurant.name}</h1>
      <ReservationForm
        restaurant={restaurant}
        hours={hours ?? []}
        sections={sections ?? []}
        layouts={layouts ?? []}
        tables={tables ?? []}
        orderId={draftOrder?.id ?? null}
        cartItems={(draftOrder?.items as unknown as CartItem[] | undefined) ?? []}
        paymentReturn={paymentReturn}
      />
    </main>
  );
}
