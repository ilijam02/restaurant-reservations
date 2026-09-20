// Restaurant names are unique among live restaurants, case- and
// whitespace-insensitively (restaurants_live_name_unique_idx in
// 20260920110000_restaurant_name_unique.sql). Both write sites - the owner's
// "Dodaj restoran" form and the edit form's rename - map a violation to this
// message instead of the generic save error.
export const RESTAURANT_NAME_TAKEN_ERROR = "Restoran sa tim nazivom već postoji. Izaberite drugi naziv.";

// 23505 is any unique violation and restaurants may gain others, so tell them
// apart by index name, same as the check-constraint handling in the edit form.
export function isRestaurantNameTaken(error: { code?: string; message?: string } | null | undefined): boolean {
  return error?.code === "23505" && (error.message ?? "").includes("restaurants_live_name_unique_idx");
}
