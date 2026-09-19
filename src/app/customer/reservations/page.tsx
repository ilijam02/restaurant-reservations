import { AppHeader } from "@/components/app-header";
import { ReservationsList, type ReservationRow } from "@/components/reservations-list";
import { RESERVATION_LIST_SELECT } from "@/lib/reservation-select";
import { createClient } from "@/lib/supabase/server";

export default async function CustomerReservationsPage() {
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
      <ReservationsList
        reservations={(reservations as unknown as ReservationRow[] | null) ?? []}
        now={now}
        perspective="customer"
      />
    </main>
  );
}
