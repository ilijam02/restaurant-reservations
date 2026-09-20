"use server";

import { deletionBlockedMessage, fetchAccountDeletionPlan } from "@/lib/account-deletion";
import { releaseVerifier, verifyPassword } from "@/lib/auth/verify-password";
import { removeRestaurantImageFolder } from "@/lib/image-upload";
import { createClient } from "@/lib/supabase/server";

export type DeleteAccountResult = { ok: true } | { ok: false; error: string };

const DELETE_FAILED_ERROR = "Brisanje naloga nije uspelo. Pokušajte ponovo.";
const EMAIL_MISMATCH_ERROR = "Uneti email se ne poklapa sa vašim nalogom.";
const WRONG_PASSWORD_ERROR = "Pogrešna lozinka.";
const IMAGES_FAILED_ERROR = "Brisanje slika restorana nije uspelo. Nalog nije obrisan - pokušajte ponovo.";

// Role-agnostic on purpose: what deleting means for an owner, a customer or an
// employee is decided in the database (see delete_my_account()); this only
// re-verifies who is asking, refuses early with a readable reason, and does the
// one thing SQL can't - removing the owner's image files.
//
// The password is checked here (see verifyPassword() for why that is a guard
// against a misclick or an unattended browser, not a security boundary).
//
// Order matters, as in deleteRestaurantAction: the image folders can only be
// removed while the restaurant rows still exist (the storage policy checks
// ownership through them), so they go first - but only for the restaurants that
// will really be deleted, and only after checking nothing blocks the deletion.
// If the files fail to go, nothing is deleted and the user can retry. If the
// RPC itself then fails (a booking slipped in, network), some restaurants have
// lost their images while staying live; the image components fall back to the
// placeholder when a file fails to load, and re-uploading fixes it.
export async function deleteAccountAction(typedEmail: string, password: string): Promise<DeleteAccountResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user?.email) return { ok: false, error: DELETE_FAILED_ERROR };

  if (typeof typedEmail !== "string" || typedEmail.trim().toLowerCase() !== user.email.toLowerCase()) {
    return { ok: false, error: EMAIL_MISMATCH_ERROR };
  }
  if (typeof password !== "string" || password.length === 0) {
    return { ok: false, error: WRONG_PASSWORD_ERROR };
  }

  const verifier = await verifyPassword(user.email, password);
  if (!verifier) return { ok: false, error: WRONG_PASSWORD_ERROR };
  await releaseVerifier(verifier);

  const plan = await fetchAccountDeletionPlan(supabase);
  if (!plan) return { ok: false, error: DELETE_FAILED_ERROR };
  const blocked = deletionBlockedMessage(plan);
  if (blocked) return { ok: false, error: blocked };

  for (const restaurantId of plan.restaurants_to_delete) {
    if (!(await removeRestaurantImageFolder(supabase, restaurantId))) {
      return { ok: false, error: IMAGES_FAILED_ERROR };
    }
  }

  const { error } = await supabase.rpc("delete_my_account");
  if (error) {
    // The RPC's own messages (raised with the default P0001) are already
    // user-facing Serbian; anything else (network, permission) isn't.
    return { ok: false, error: error.code === "P0001" ? error.message : DELETE_FAILED_ERROR };
  }

  // The user is gone, so this may well fail server-side; what matters is that
  // it clears the session cookies on the way.
  await supabase.auth.signOut().catch(() => {});

  return { ok: true };
}
