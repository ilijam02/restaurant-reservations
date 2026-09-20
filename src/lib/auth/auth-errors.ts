// Turns Supabase Auth's error codes into messages a person can act on, shared
// by the signup page and the account form. Pure, so it is unit-tested; an
// unknown code returns null and the caller shows its own generic message.
// (Codes: https://supabase.com/docs/guides/auth/debugging/error-codes)

export type AuthErrorInfo = {
  // The input the message belongs under; absent for a form-level message.
  field?: "email" | "password";
  message: string;
};

export function describeAuthError(error: { code?: string; status?: number } | null | undefined): AuthErrorInfo | null {
  if (!error) return null;

  switch (error.code) {
    case "email_exists":
    case "user_already_exists":
      return { field: "email", message: "Nalog sa ovim emailom već postoji." };
    case "email_address_invalid":
      return {
        field: "email",
        message: "Ova email adresa nije prihvaćena. Proverite da postoji i da može da prima poštu.",
      };
    case "email_address_not_authorized":
      return { field: "email", message: "Na ovu adresu trenutno ne možemo da pošaljemo poruku. Probajte drugu." };
    case "weak_password":
      return { field: "password", message: "Lozinka je previše slaba. Izaberite drugu." };
    case "same_password":
      return { field: "password", message: "Nova lozinka mora da se razlikuje od trenutne." };
    case "over_email_send_rate_limit":
      return {
        message: "Poslato je previše poruka za potvrdu. Sačekajte oko sat vremena i pokušajte ponovo.",
      };
    case "over_request_rate_limit":
      return { message: "Previše pokušaja. Sačekajte nekoliko minuta i pokušajte ponovo." };
    default:
      return error.status === 429 ? { message: "Previše pokušaja. Sačekajte nekoliko minuta i pokušajte ponovo." } : null;
  }
}
