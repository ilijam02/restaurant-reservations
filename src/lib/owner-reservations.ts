import type { ReservationRow } from "@/components/reservations-list";
import type { createClient } from "@/lib/supabase/server";
import { OWNER_RESERVATION_LIST_SELECT } from "@/lib/reservation-select";

// PostgREST turns `.in()` into part of the request URL, so a very long id
// list (every distinct customer an owner has ever had) can overflow URL length
// limits - looked up in chunks instead.
const PROFILE_LOOKUP_CHUNK_SIZE = 100;

export const OWNER_RESERVATIONS_LOAD_ERROR = "Učitavanje rezervacija nije uspelo. Osvežite stranicu i pokušajte ponovo.";

// A booking whose customer deleted their account keeps its row with
// customer_id set to null. That is not the same as a failed profile lookup
// (name stays null and the list falls back to "Nepoznat korisnik").
export const DELETED_CUSTOMER_NAME = "Obrisan korisnik";

export function resolveCustomerName(customerId: string | null, nameById: Map<string, string>): string | null {
  if (customerId === null) return DELETED_CUSTOMER_NAME;
  return nameById.get(customerId) ?? null;
}

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
//
// A failure of either query is reported as `error` rather than swallowed:
// otherwise a failed reservations query would render as "no reservations" and
// a failed profiles query as every guest being "Nepoznat korisnik".
export async function fetchOwnerReservations(
  supabase: Awaited<ReturnType<typeof createClient>>,
  restaurantId?: string,
): Promise<{ reservations: ReservationRow[]; error: string | null }> {
  // !inner + the archived_at filter keeps the archived (deleted) restaurants'
  // reservations out of the owner's all-restaurants view; they stay in the
  // database for the customers' own histories.
  let query = supabase
    .from("reservations")
    .select(OWNER_RESERVATION_LIST_SELECT)
    .is("restaurants.archived_at", null)
    .order("starts_at", { ascending: false });
  if (restaurantId) {
    query = query.eq("restaurant_id", restaurantId);
  }
  const { data, error } = await query;
  if (error) {
    return { reservations: [], error: OWNER_RESERVATIONS_LOAD_ERROR };
  }
  const reservations = (data as unknown as ReservationRow[] | null) ?? [];

  const customerIds = [
    ...new Set(reservations.map((reservation) => reservation.customer_id).filter((id): id is string => id !== null)),
  ];
  const chunks: string[][] = [];
  for (let i = 0; i < customerIds.length; i += PROFILE_LOOKUP_CHUNK_SIZE) {
    chunks.push(customerIds.slice(i, i + PROFILE_LOOKUP_CHUNK_SIZE));
  }
  const results = await Promise.all(
    chunks.map((chunk) => supabase.from("profiles").select("id, first_name, last_name").in("id", chunk)),
  );
  if (results.some((result) => result.error)) {
    return { reservations: [], error: OWNER_RESERVATIONS_LOAD_ERROR };
  }

  const nameById = new Map(
    results.flatMap((result) => result.data ?? []).map((profile) => [profile.id, `${profile.first_name} ${profile.last_name}`]),
  );

  return {
    reservations: reservations.map((reservation) => ({
      ...reservation,
      customer_name: resolveCustomerName(reservation.customer_id, nameById),
    })),
    error: null,
  };
}
