import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { AppHeader } from "@/components/app-header";
import {
  EmployeeRestaurantReservationsList,
  type EmployeeReservationRow,
} from "@/components/employee-restaurant-reservations-list";

export default async function EmployeeRestaurantReservationsPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: staffRow } = await supabase
    .from("restaurant_staff")
    .select("restaurants(id, name)")
    .eq("restaurant_id", id)
    .eq("employee_id", user!.id)
    .eq("status", "accepted")
    .maybeSingle();

  const restaurant = (staffRow as unknown as { restaurants: { id: string; name: string } | null } | null)
    ?.restaurants;

  if (!restaurant) {
    notFound();
  }

  // "Active" matches is_active_reservation_status() in the DB - a
  // reservation mid-service (preparing_order/order_prepared/ongoing) is
  // still "current" from the employee's point of view, not just a plain
  // 'confirmed' one.
  const now = new Date().toISOString();
  const { data: reservations } = await supabase
    .from("reservations")
    .select(
      "id, party_size, starts_at, status, reservation_tables(tables(name)), reservation_sections(sections(name)), orders(status, payment_status)",
    )
    .eq("restaurant_id", id)
    .in("status", ["confirmed", "preparing_order", "order_prepared", "ongoing"])
    .gte("ends_at", now)
    .order("starts_at");

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/employee" />
      <h1 className="text-3xl font-bold">{restaurant.name}</h1>
      <h2 className="text-lg font-semibold">Trenutne rezervacije</h2>
      <EmployeeRestaurantReservationsList
        reservations={(reservations as unknown as EmployeeReservationRow[] | null) ?? []}
        now={now}
      />
    </main>
  );
}
