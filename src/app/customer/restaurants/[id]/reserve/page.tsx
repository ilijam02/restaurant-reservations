import { notFound } from "next/navigation";
import { AppHeader } from "@/components/app-header";
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
  searchParams: Promise<{ payment?: string; reservation?: string }>;
}) {
  const { id } = await params;
  const { payment, reservation: returnedReservationId } = await searchParams;
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
  // after they paid for - or backed out of paying for - the reservation they
  // just made, so the page ends the way it does when there's no order: the plain
  // form plus a message. Which reservation comes from the URL, so it's looked up
  // (RLS scopes it to the caller's own) rather than trusted, and only used if it
  // belongs to this restaurant. The webhook can land a moment after the redirect,
  // so "received" is all the success text claims; the reservations list shows the
  // actual payment status.
  let initialConfirmation: string | null = null;
  let initialError: string | null = null;
  if ((payment === "success" || payment === "cancelled") && returnedReservationId && UUID_PATTERN.test(returnedReservationId)) {
    const { data: returned } = await supabase
      .from("reservations")
      .select("starts_at")
      .eq("id", returnedReservationId)
      .eq("restaurant_id", id)
      .maybeSingle();

    if (returned) {
      const when = formatReservationTime(returned.starts_at);
      if (payment === "success") {
        initialConfirmation = `Potvrđeno: rezervacija za ${when}. Hvala! Plaćanje je primljeno.`;
      } else {
        initialError = `Rezervacija za ${when} je potvrđena, ali plaćanje je otkazano. Porudžbinu možete platiti u "Moje rezervacije".`;
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
        initialConfirmation={initialConfirmation}
        initialError={initialError}
      />
    </main>
  );
}
