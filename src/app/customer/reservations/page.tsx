import { AppHeader } from "@/components/app-header";
import { CustomerReservationsList, type ReservationRow } from "@/components/customer-reservations-list";
import { createClient } from "@/lib/supabase/server";

export default async function CustomerReservationsPage() {
  const supabase = await createClient();

  // RLS scopes this to the caller's own reservations regardless of status
  // (see reservations' "Customers can view their own reservations" policy) -
  // no explicit customer_id filter needed. orders is a reverse join on
  // orders.reservation_id; only confirmed orders ever carry one (set once by
  // create_reservation()'s p_order_id finalization), so at most one per
  // reservation in practice even though the FK itself isn't unique.
  const { data: reservations } = await supabase
    .from("reservations")
    .select(
      "id, party_size, starts_at, ends_at, status, restaurants(name), reservation_tables(tables(name)), reservation_sections(party_size, sections(name)), orders(status, items:order_items(id, item_name, unit_price, quantity, choices:order_item_choices(option_name, choice_name, price_delta)))",
    )
    .order("starts_at", { ascending: false });

  // Computed once here rather than inside the client list component, so the
  // server render and the client hydration pass classify current/past
  // identically - see CustomerReservationsList's own comment on `now`.
  const now = new Date().toISOString();

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/customer" />
      <h1 className="text-3xl font-bold">Moje rezervacije</h1>
      <CustomerReservationsList reservations={(reservations as unknown as ReservationRow[] | null) ?? []} now={now} />
    </main>
  );
}
