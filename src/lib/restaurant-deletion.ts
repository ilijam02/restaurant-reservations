import type { createClient } from "@/lib/supabase/server";

// One row of restaurant_deletion_plan() (see 20260919180000_delete_restaurant.sql).
export type DeletionPlan = {
  active_reservations: number;
  cancellable_reservations: number;
  total_reservations: number;
  staff_count: number;
  menu_item_count: number;
  table_count: number;
};

// null when the restaurant doesn't exist, isn't the caller's, is already
// archived - or the lookup failed.
export async function fetchDeletionPlan(
  supabase: Awaited<ReturnType<typeof createClient>>,
  restaurantId: string,
): Promise<DeletionPlan | null> {
  const { data, error } = await supabase.rpc("restaurant_deletion_plan", { p_restaurant_id: restaurantId }).maybeSingle();
  if (error || !data) return null;
  return data as DeletionPlan;
}
