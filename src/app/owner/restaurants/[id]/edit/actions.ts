"use server";

import { getProfileRole } from "@/lib/auth/role";
import { geocodeAddress, type GeocodeResult } from "@/lib/geocode";
import { createClient } from "@/lib/supabase/server";

export type GeocodeActionResult =
  | { ok: true; result: GeocodeResult }
  | { ok: false; error: string };

const NOT_FOUND_ERROR = "Adresa nije pronađena. Proverite je ili postavite pin ručno na mapi.";
const UNAVAILABLE_ERROR = "Pretraga adrese trenutno nije dostupna. Pokušajte ponovo ili postavite pin ručno na mapi.";
const BUSY_ERROR = "Pretraga adrese je trenutno zauzeta. Pokušajte ponovo za trenutak ili postavite pin ručno na mapi.";
const MAX_ADDRESS_LENGTH = 300;
// Just over the 1.1s window claim_geocode_slot() enforces, so one retry after
// waiting is enough to get the slot when it was only briefly taken.
const SLOT_RETRY_DELAY_MS = 1200;

let warnedAboutMissingContact = false;

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

  // Nominatim allows 1 request/second for this whole app, however many owners
  // are searching. The database hands out that one slot (see
  // claim_geocode_slot()); if someone else just used it, wait it out once and
  // try again before giving up.
  let claimed = await claimSlot(supabase);
  if (claimed === false) {
    await new Promise((resolve) => setTimeout(resolve, SLOT_RETRY_DELAY_MS));
    claimed = await claimSlot(supabase);
  }
  if (claimed === null) return { ok: false, error: UNAVAILABLE_ERROR };
  if (!claimed) return { ok: false, error: BUSY_ERROR };

  // Nominatim asks for a User-Agent that identifies the app with a contact.
  // Optional so local dev works without it, but production should set it.
  const contact = process.env.GEOCODING_CONTACT;
  if (!contact && process.env.NODE_ENV === "production" && !warnedAboutMissingContact) {
    warnedAboutMissingContact = true;
    console.warn(
      "GEOCODING_CONTACT is not set: Nominatim requests go out without a contact in the User-Agent, which its usage policy asks for.",
    );
  }
  const userAgent = `RestaurantReservations/0.1${contact ? ` (${contact})` : ""}`;

  const outcome = await geocodeAddress(trimmed, userAgent);
  if (outcome.ok) return { ok: true, result: outcome.result };
  return { ok: false, error: outcome.error === "not_found" ? NOT_FOUND_ERROR : UNAVAILABLE_ERROR };
}

// true = got the slot, false = someone else has it, null = the call itself
// failed (fail closed: no slot, no request to Nominatim).
async function claimSlot(supabase: Awaited<ReturnType<typeof createClient>>): Promise<boolean | null> {
  const { data, error } = await supabase.rpc("claim_geocode_slot");
  if (error) {
    console.error("claim_geocode_slot failed", error.message);
    return null;
  }
  return data === true;
}
