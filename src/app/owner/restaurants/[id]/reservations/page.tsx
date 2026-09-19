import { notFound } from "next/navigation";
import { AppHeader } from "@/components/app-header";
import { CancelAllReservations } from "@/components/cancel-all-reservations";
import { ReservationsList } from "@/components/reservations-list";
import { fetchOwnerReservations } from "@/lib/owner-reservations";
import { fetchDeletionPlan } from "@/lib/restaurant-deletion";
import { createClient } from "@/lib/supabase/server";

export default async function OwnerRestaurantReservationsPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: restaurant } = await supabase
    .from("restaurants")
    .select("id, name")
    .eq("id", id)
    .eq("owner_id", user!.id)
    .is("archived_at", null)
    .single();

  if (!restaurant) {
    notFound();
  }

  const { reservations, error } = await fetchOwnerReservations(supabase, id);

  // Only for the "cancel all" button; a failed lookup just leaves it out.
  const plan = await fetchDeletionPlan(supabase, id);

  // Computed once here rather than inside the client list component - see
  // ReservationsList's own comment on `now`.
  const now = new Date().toISOString();

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/owner" />
      <h1 className="text-3xl font-bold">{restaurant.name}</h1>
      {plan && (
        <CancelAllReservations
          restaurantId={restaurant.id}
          restaurantName={restaurant.name}
          cancellableCount={plan.cancellable_reservations}
          ongoingCount={Math.max(0, plan.active_reservations - plan.cancellable_reservations)}
        />
      )}
      {error ? (
        <p role="alert" className="text-red-600 dark:text-red-400">
          {error}
        </p>
      ) : (
        <ReservationsList reservations={reservations} now={now} perspective="owner" />
      )}
    </main>
  );
}
