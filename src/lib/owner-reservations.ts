import type { ReservationRow } from "@/components/reservations-list";
import type { createClient } from "@/lib/supabase/server";
import { RESERVATION_LIST_SELECT } from "@/lib/reservation-select";

// RLS ("Owners can view reservations at their restaurants") already limits
// this to the caller's own restaurants, so the all-restaurants view needs no
// explicit filter; restaurantId narrows it to a single one for the
// per-restaurant page (whose caller checks ownership separately, to 404 on a
// restaurant that isn't theirs instead of rendering an empty list).
//
// reservations.customer_id points at auth.users, not profiles, so PostgREST
// can't embed the customer's name in the same query - it's a second lookup
// (allowed by the "Owners can view profiles of customers who reserved at
// their restaurants" policy).
export async function fetchOwnerReservations(
  supabase: Awaited<ReturnType<typeof createClient>>,
  restaurantId?: string,
): Promise<ReservationRow[]> {
  let query = supabase.from("reservations").select(RESERVATION_LIST_SELECT).order("starts_at", { ascending: false });
  if (restaurantId) {
    query = query.eq("restaurant_id", restaurantId);
  }
  const { data } = await query;
  const reservations = (data as unknown as (ReservationRow & { customer_id: string })[] | null) ?? [];

  const customerIds = [...new Set(reservations.map((reservation) => reservation.customer_id))];
  const { data: profiles } = customerIds.length
    ? await supabase.from("profiles").select("id, first_name, last_name").in("id", customerIds)
    : { data: [] };
  const nameById = new Map((profiles ?? []).map((profile) => [profile.id, `${profile.first_name} ${profile.last_name}`]));

  return reservations.map((reservation) => ({
    ...reservation,
    customer_name: nameById.get(reservation.customer_id) ?? null,
  }));
}
