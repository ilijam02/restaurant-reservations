"use server";

import { getProfileRole } from "@/lib/auth/role";
import { geocodeAddress, type GeocodeResult } from "@/lib/geocode";
import { createClient } from "@/lib/supabase/server";

export type GeocodeActionResult =
  | { ok: true; result: GeocodeResult }
  | { ok: false; error: string };

const NOT_FOUND_ERROR = "Adresa nije pronađena. Proverite je ili postavite pin ručno na mapi.";
const UNAVAILABLE_ERROR = "Pretraga adrese trenutno nije dostupna. Pokušajte ponovo ili postavite pin ručno na mapi.";
const MAX_ADDRESS_LENGTH = 300;

// A Server Action is a public POST endpoint whatever page imports it, so it
// re-checks who's calling instead of trusting the page's route gate: only a
// signed-in owner-role account may spend the shared Nominatim quota.
export async function geocodeAddressAction(address: string): Promise<GeocodeActionResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user || (await getProfileRole(supabase, user.id)) !== "owner") {
    return { ok: false, error: UNAVAILABLE_ERROR };
  }

  const trimmed = typeof address === "string" ? address.trim() : "";
  if (!trimmed || trimmed.length > MAX_ADDRESS_LENGTH) {
    return { ok: false, error: NOT_FOUND_ERROR };
  }

  // Nominatim asks for a User-Agent that identifies the app (and ideally a
  // contact). GEOCODING_CONTACT is optional so local dev works without it.
  const contact = process.env.GEOCODING_CONTACT;
  const userAgent = `RestaurantReservations/0.1${contact ? ` (${contact})` : ""}`;

  const outcome = await geocodeAddress(trimmed, userAgent);
  if (outcome.ok) return { ok: true, result: outcome.result };
  return { ok: false, error: outcome.error === "not_found" ? NOT_FOUND_ERROR : UNAVAILABLE_ERROR };
}
