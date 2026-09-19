import type { createClient } from "@/lib/supabase/server";
import type { Role } from "@/lib/auth/redirect";

export type BlockingRestaurant = { id: string; name: string; active_reservations: number };

// The one row of account_deletion_plan() (see 20260919200000_account_deletion.sql).
export type AccountDeletionPlan = {
  role: Role;
  // The caller's own bookings (as a customer) that are still active.
  active_reservations: number;
  // Everything the caller ever booked; it stays behind, anonymized.
  history_reservations: number;
  // Owned restaurants that have an active reservation.
  blocking_restaurants: BlockingRestaurant[];
  // Owned restaurants that will be really deleted (no reservation history) -
  // the ids whose image folders have to be purged first.
  restaurants_to_delete: string[];
  // Owned restaurants that will be archived and detached (they have history).
  restaurants_to_archive: number;
};

// null when the lookup failed or the caller has no profile.
export async function fetchAccountDeletionPlan(
  supabase: Awaited<ReturnType<typeof createClient>>,
): Promise<AccountDeletionPlan | null> {
  const { data, error } = await supabase.rpc("account_deletion_plan").maybeSingle();
  if (error || !data) return null;
  return data as AccountDeletionPlan;
}

const ACTIVE_SUFFIX = "ima aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.";

// Why the account can't be deleted right now, worded like the database's own
// refusal (delete_my_account() raises the same text), or null when nothing
// blocks it. A customer's own bookings come first, then the first owned
// restaurant with an active one.
export function deletionBlockedMessage(plan: AccountDeletionPlan): string | null {
  if (plan.active_reservations > 0) return "Imate aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.";
  const [first] = plan.blocking_restaurants;
  if (first) return `Restoran „${first.name}” ${ACTIVE_SUFFIX}`;
  return null;
}
