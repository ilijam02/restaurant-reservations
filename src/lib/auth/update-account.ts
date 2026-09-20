"use server";

import { describeAuthError } from "@/lib/auth/auth-errors";
import { releaseVerifier, verifyPassword } from "@/lib/auth/verify-password";
import { updateUserEmailAsAdmin } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";
import { validateAccountForm, type AccountFieldErrors, type AccountFormInput } from "@/lib/validation";

export type UpdateAccountResult =
  | { ok: true; message: string }
  // authChanged: the email and/or password were already changed when the
  // failure happened (the profile write after them failed), so the password the
  // user typed as "current" is stale and the form has to start over from what
  // is now stored - see EditAccountSection.
  | { ok: false; error?: string; errors?: AccountFieldErrors; authChanged?: boolean };

const SAVE_FAILED_ERROR = "Čuvanje izmena nije uspelo. Pokušajte ponovo.";
const WRONG_PASSWORD_ERROR = "Pogrešna lozinka.";
const EMAIL_UNAVAILABLE_ERROR = "Promena emaila trenutno nije dostupna. Pokušajte ponovo kasnije.";

// A Server Action is a public POST endpoint, so its argument is untrusted
// whatever the form sends: anything that isn't a string counts as empty.
function sanitize(input: unknown): AccountFormInput {
  const record = (typeof input === "object" && input !== null ? input : {}) as Record<string, unknown>;
  const pick = (name: keyof AccountFormInput) => (typeof record[name] === "string" ? (record[name] as string) : "");
  return {
    firstName: pick("firstName"),
    lastName: pick("lastName"),
    email: pick("email"),
    phone: pick("phone"),
    newPassword: pick("newPassword"),
    confirmNewPassword: pick("confirmNewPassword"),
    currentPassword: pick("currentPassword"),
  };
}

// Edits the signed-in user's own name, email, phone and password.
//
// The rules (validation.ts) run again here - the form's copy is only for
// instant feedback - and only what actually changed is validated or written.
// Changing email, phone or password needs the current password (verified on a
// throwaway client, see verifyPassword()).
//
// Order: validate everything, then the auth change (email/password; the step
// that can be refused for reasons only Auth knows, like a taken email), then
// the profile row. So a refused email leaves nothing half-saved; the reverse
// failure (auth changed, profile write failed) is reported as such.
//
// Two ways to change the auth side, neither of which sends an email:
//  - a password-only change goes through the verifier's fresh session rather
//    than the cookie session: Supabase's "secure password change" wants a recent
//    sign-in, which a months-old cookie session isn't, and the cookie session is
//    left untouched (other sessions stay signed in);
//  - an email change (with the new password in the same call, if any) is applied
//    directly by the admin API (see updateUserEmailAsAdmin()), because Auth's own
//    email change sends confirmation messages the app doesn't want, is capped at
//    a few an hour, and only takes effect once a link is clicked.
export async function updateAccountAction(rawInput: AccountFormInput): Promise<UpdateAccountResult> {
  const input = sanitize(rawInput);

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user?.email) return { ok: false, error: SAVE_FAILED_ERROR };

  // The id filter matters: an owner's RLS also lets them read their staff's and
  // customers' profiles.
  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("first_name, last_name, phone")
    .eq("id", user.id)
    .maybeSingle();
  if (profileError || !profile) return { ok: false, error: SAVE_FAILED_ERROR };

  const validated = validateAccountForm(
    { firstName: profile.first_name, lastName: profile.last_name, email: user.email, phone: profile.phone },
    input,
  );
  if (!validated.ok) return { ok: false, errors: validated.errors };

  const { values, changes } = validated;
  if (!changes.name && !changes.email && !changes.phone && !changes.password) {
    return { ok: true, message: "Nema izmena za čuvanje." };
  }

  let authChanged = false;

  if (changes.needsCurrentPassword) {
    const verifier = await verifyPassword(user.email, input.currentPassword);
    if (!verifier) return { ok: false, errors: { currentPassword: WRONG_PASSWORD_ERROR } };

    try {
      if (changes.email) {
        // user.id is the server-verified session's, never the request's.
        const result = await updateUserEmailAsAdmin(user.id, {
          email: values.email,
          ...(changes.password ? { password: input.newPassword } : {}),
        });
        if (!result.ok && "unavailable" in result) {
          console.error("updateAccountAction: SUPABASE_SERVICE_ROLE_KEY is not set, so the email can't be changed");
          return { ok: false, error: EMAIL_UNAVAILABLE_ERROR };
        }
        if (!result.ok) return mapAuthError(result.error);
        authChanged = true;
      } else if (changes.password) {
        const { error } = await verifier.auth.updateUser({ password: input.newPassword });
        if (error) return mapAuthError(error);
        authChanged = true;
      }
    } finally {
      await releaseVerifier(verifier);
    }
  }

  if (changes.name || changes.phone) {
    const { error } = await supabase
      .from("profiles")
      .update({
        ...(changes.name ? { first_name: values.firstName, last_name: values.lastName } : {}),
        ...(changes.phone ? { phone: values.phone } : {}),
      })
      .eq("id", user.id);
    if (error) {
      return authChanged
        ? {
            ok: false,
            authChanged: true,
            error:
              "Email ili lozinka su promenjeni, ali ime i telefon nisu sačuvani. Pokušajte ponovo (ako ste promenili lozinku, trenutna lozinka je sada nova).",
          }
        : { ok: false, error: SAVE_FAILED_ERROR };
    }
  }

  return { ok: true, message: "Izmene su sačuvane." };
}

// The shared describeAuthError() knows the codes worth a specific message; its
// "password" field is this form's new-password input. Anything else is logged
// (code and status only - the message can contain the address) and shown as the
// generic failure.
function mapAuthError(error: { code?: string; status?: number }): UpdateAccountResult {
  const info = describeAuthError(error);
  if (!info) {
    console.error("updateAccountAction: auth update failed", { code: error.code, status: error.status });
    return { ok: false, error: SAVE_FAILED_ERROR };
  }
  if (info.field === "email") return { ok: false, errors: { email: info.message } };
  if (info.field === "password") return { ok: false, errors: { newPassword: info.message } };
  return { ok: false, error: info.message };
}
