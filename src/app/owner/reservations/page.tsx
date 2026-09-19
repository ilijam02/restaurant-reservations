import { AppHeader } from "@/components/app-header";
import { ReservationsList } from "@/components/reservations-list";
import { fetchOwnerReservations } from "@/lib/owner-reservations";
import { createClient } from "@/lib/supabase/server";

export default async function OwnerReservationsPage() {
  const supabase = await createClient();
  const { reservations, error } = await fetchOwnerReservations(supabase);

  // Computed once here rather than inside the client list component - see
  // ReservationsList's own comment on `now`.
  const now = new Date().toISOString();

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/owner" />
      <h1 className="text-3xl font-bold">Sve rezervacije</h1>
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
