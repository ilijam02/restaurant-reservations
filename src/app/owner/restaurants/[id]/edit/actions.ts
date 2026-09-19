"use server";

import { getProfileRole } from "@/lib/auth/role";
import { geocodeAddress, type GeocodeResult } from "@/lib/geocode";
import { removeRestaurantImageFolder } from "@/lib/image-upload";
import { fetchDeletionPlan } from "@/lib/restaurant-deletion";
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

export type DeleteRestaurantResult =
  | { ok: true; outcome: "deleted" | "archived" }
  | { ok: false; error: string };

const DELETE_FAILED_ERROR = "Brisanje restorana nije uspelo. Pokušajte ponovo.";
const IMAGES_FAILED_ERROR = "Brisanje slika restorana nije uspelo. Restoran nije obrisan - pokušajte ponovo.";
const NOT_FOUND_RESTAURANT_ERROR = "Restoran ne postoji.";

// Deletes the restaurant, or archives it if it has reservation history (that
// choice is delete_restaurant()'s, in the database). Order matters: the
// restaurant's image files can only be removed while its row still exists (the
// storage policy checks ownership through it), so they go first - but only on
// the path where the row will really be deleted, and only after checking that
// nothing blocks the delete, so a refused delete never costs the images. If the
// files fail to go, nothing is deleted and the owner can retry. A booking that
// slips in between the plan check and the delete is still refused by
// delete_restaurant() itself, at the cost of that restaurant having lost its
// images. The same happens if the delete call fails for any other reason
// (network drop, DB error) right after a successful purge: the restaurant
// stays live with image_url values pointing at removed files. That's
// tolerable - RestaurantImage/MenuItemImage fall back to the placeholder when
// a file fails to load (see FallbackImage), and re-uploading fixes it. The
// order can't be flipped, since the storage policy needs the restaurant row.
export async function deleteRestaurantAction(restaurantId: string): Promise<DeleteRestaurantResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user || (await getProfileRole(supabase, user.id)) !== "owner") {
    return { ok: false, error: DELETE_FAILED_ERROR };
  }

  const plan = await fetchDeletionPlan(supabase, restaurantId);
  if (!plan) return { ok: false, error: NOT_FOUND_RESTAURANT_ERROR };
  if (plan.active_reservations > 0) {
    return {
      ok: false,
      error: "Restoran ima aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.",
    };
  }

  if (plan.total_reservations === 0 && !(await removeRestaurantImageFolder(supabase, restaurantId))) {
    return { ok: false, error: IMAGES_FAILED_ERROR };
  }

  const { data: outcome, error } = await supabase.rpc("delete_restaurant", { p_restaurant_id: restaurantId });
  if (error) {
    // The RPC's own messages (raised with the default P0001) are already
    // user-facing Serbian; anything else (network, permission) isn't.
    return { ok: false, error: error.code === "P0001" ? error.message : DELETE_FAILED_ERROR };
  }

  return { ok: true, outcome: outcome === "archived" ? "archived" : "deleted" };
}
