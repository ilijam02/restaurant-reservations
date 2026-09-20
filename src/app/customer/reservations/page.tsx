import { AppHeader } from "@/components/app-header";
import { ReservationsList, type ReservationRow } from "@/components/reservations-list";
import { RESERVATION_LIST_SELECT } from "@/lib/reservation-select";
import { createClient } from "@/lib/supabase/server";

// Where Stripe's Checkout sends the customer back to (create-checkout sets
// ?payment=success|cancelled). The order's real state comes from the webhook,
// which can land a moment after the redirect, so the success text doesn't claim
// more than "received" - the card below shows the actual payment status.
const PAYMENT_BANNERS: Record<string, { text: string; className: string }> = {
  success: {
    text: "Hvala! Plaćanje je primljeno. Status porudžbine će se osvežiti za nekoliko trenutaka.",
    className: "text-success",
  },
  cancelled: {
    text: "Plaćanje je otkazano. Porudžbina je i dalje neplaćena - možete je platiti ovde.",
    className: "text-amber-700 dark:text-warning",
  },
};

export default async function CustomerReservationsPage({
  searchParams,
}: {
  searchParams: Promise<{ payment?: string }>;
}) {
  const { payment } = await searchParams;
  // hasOwn: the value is user-controlled, so "constructor" and friends must not match.
  const banner = payment && Object.hasOwn(PAYMENT_BANNERS, payment) ? PAYMENT_BANNERS[payment] : undefined;
  const supabase = await createClient();

  // RLS scopes this to the caller's own reservations regardless of status
  // (see reservations' "Customers can view their own reservations" policy) -
  // no explicit customer_id filter needed.
  const { data: reservations } = await supabase
    .from("reservations")
    .select(RESERVATION_LIST_SELECT)
    .order("starts_at", { ascending: false });

  // Computed once here rather than inside the client list component, so the
  // server render and the client hydration pass classify current/past
  // identically - see ReservationsList's own comment on `now`.
  const now = new Date().toISOString();

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/customer" />
      <h1 className="text-3xl font-bold">Moje rezervacije</h1>
      {banner && (
        <p role="status" className={`w-full max-w-lg text-sm font-medium ${banner.className}`}>
          {banner.text}
        </p>
      )}
      <ReservationsList
        reservations={(reservations as unknown as ReservationRow[] | null) ?? []}
        now={now}
        perspective="customer"
      />
    </main>
  );
}
