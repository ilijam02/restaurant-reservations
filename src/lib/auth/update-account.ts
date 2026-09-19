"use server";

import { releaseVerifier, verifyPassword } from "@/lib/auth/verify-password";
import { createClient } from "@/lib/supabase/server";
import { validateAccountForm, type AccountFieldErrors, type AccountFormInput } from "@/lib/validation";

export type UpdateAccountResult =
  | { ok: true; message: string }
  | { ok: false; error?: string; errors?: AccountFieldErrors };

const SAVE_FAILED_ERROR = "Čuvanje izmena nije uspelo. Pokušajte ponovo.";
const RATE_LIMITED_ERROR = "Previše pokušaja. Pokušajte ponovo za nekoliko minuta.";
const WRONG_PASSWORD_ERROR = "Pogrešna lozinka.";

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
// The auth change goes through the verifier's fresh session rather than the
// cookie session: Supabase's "secure password change" wants a recent sign-in,
// which a months-old cookie session isn't, and the cookie session is left
// untouched (a password change doesn't sign out the user's other sessions).
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

  let pendingEmail: string | null = null;
  let authChanged = false;

  if (changes.needsCurrentPassword) {
    const verifier = await verifyPassword(user.email, input.currentPassword);
    if (!verifier) return { ok: false, errors: { currentPassword: WRONG_PASSWORD_ERROR } };

    try {
      if (changes.email || changes.password) {
        const { data, error } = await verifier.auth.updateUser({
          ...(changes.email ? { email: values.email } : {}),
          ...(changes.password ? { password: input.newPassword } : {}),
        });
        if (error) return mapAuthError(error);
        authChanged = true;
        // With "Confirm email" on, the address only changes once confirmed.
        if (changes.email && data.user?.new_email) pendingEmail = data.user.new_email;
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
      return {
        ok: false,
        error: authChanged
          ? "Email ili lozinka su promenjeni, ali ime i telefon nisu sačuvani. Pokušajte ponovo."
          : SAVE_FAILED_ERROR,
      };
    }
  }

  return {
    ok: true,
    message: pendingEmail
      ? `Izmene su sačuvane. Poslali smo poruku za potvrdu na ${pendingEmail} - email će biti promenjen tek kada je potvrdite.`
      : "Izmene su sačuvane.",
  };
}

// Auth's own error codes (https://supabase.com/docs/guides/auth/debugging/error-codes).
function mapAuthError(error: { code?: string; status?: number }): UpdateAccountResult {
  switch (error.code) {
    case "email_exists":
    case "user_already_exists":
      return { ok: false, errors: { email: "Ovaj email je već u upotrebi." } };
    case "email_address_invalid":
      return { ok: false, errors: { email: "Ovaj email nije prihvaćen. Probajte drugi." } };
    case "same_password":
      return { ok: false, errors: { newPassword: "Nova lozinka mora da se razlikuje od trenutne." } };
    case "weak_password":
      return { ok: false, errors: { newPassword: "Lozinka je previše slaba. Izaberite drugu." } };
    case "over_request_rate_limit":
    case "over_email_send_rate_limit":
      return { ok: false, error: RATE_LIMITED_ERROR };
    default:
      return { ok: false, error: error.status === 429 ? RATE_LIMITED_ERROR : SAVE_FAILED_ERROR };
  }
}
