// Validation shared by the signup page, the account form and the account Server
// Action. Pure functions only, so the same rules run in the browser (instant
// feedback) and on the server (the part that can't be skipped). Every validator
// returns the normalized value to store, so callers never re-clean input.

export type Validated = { ok: true; value: string } | { ok: false; error: string };

// --- Names ---------------------------------------------------------------

export const NAME_MAX_LENGTH = 50;

// Letters (any script, so Latin and Cyrillic diacritics both pass) in words
// separated by a single space, hyphen or apostrophe - "Jovanović-Petrović",
// "O'Brien", "Ana Marija", "St. John". No digits or other symbols.
const NAME_REGEX = /^[\p{L}\p{M}]+\.?(?:[ '’-][\p{L}\p{M}]+\.?)*$/u;

export function validateName(raw: string, label: "Ime" | "Prezime"): Validated {
  const value = raw.trim().replace(/\s+/g, " ");
  if (value.length === 0) return { ok: false, error: `${label} je obavezno.` };
  if (value.length > NAME_MAX_LENGTH) {
    return { ok: false, error: `${label} može imati najviše ${NAME_MAX_LENGTH} znakova.` };
  }
  if (!NAME_REGEX.test(value)) {
    return { ok: false, error: `${label} može sadržati samo slova, razmake, crtice i apostrofe.` };
  }
  return { ok: true, value };
}

// --- Email ---------------------------------------------------------------

const EMAIL_MAX_LENGTH = 254;
const EMAIL_LOCAL_MAX_LENGTH = 64;

// The local part: RFC 5322 "atext" characters in dot-separated words - no
// leading, trailing or doubled dots, no quoted strings or comments.
const EMAIL_LOCAL_REGEX = /^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*$/;
// What follows the "@": one or more letters, digits, "-" or "." (so
// subdomains work), then a dot and a TLD of 2 or more letters - or an IDN TLD
// in punycode ("xn--p1ai"). This is what rejects "a@a", "name@localhost" and
// "x@y.c". (The address is lower-cased before it is tested.)
const EMAIL_DOMAIN_REGEX = /^[a-z0-9.-]+\.(?:[a-z]{2,}|xn--[a-z0-9-]+)$/;
// On top of that, each dot-separated part must be a well-formed DNS label:
// non-empty, at most 63 characters, not starting or ending with a hyphen. That
// rules out "b..rs", ".b.rs", "b.rs." and "-b.rs", which the pattern above
// alone would let through.
const DOMAIN_LABEL_REGEX = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

export function validateEmail(raw: string): Validated {
  const value = raw.trim().toLowerCase();
  const error = "Unesite ispravnu email adresu, na primer ime@domen.rs.";
  if (value.length === 0) return { ok: false, error: "Email je obavezan." };
  if (value.length > EMAIL_MAX_LENGTH) return { ok: false, error };

  const parts = value.split("@");
  if (parts.length !== 2) return { ok: false, error };
  const [local, domain] = parts;
  if (local.length > EMAIL_LOCAL_MAX_LENGTH || !EMAIL_LOCAL_REGEX.test(local)) return { ok: false, error };

  if (!EMAIL_DOMAIN_REGEX.test(domain)) return { ok: false, error };
  if (!domain.split(".").every((label) => DOMAIN_LABEL_REGEX.test(label))) return { ok: false, error };

  return { ok: true, value };
}

// --- Phone ---------------------------------------------------------------

// Only digits, spaces and the usual separators; a "+" only as the first
// character. Anything else (letters, "ext", emoji) is rejected outright.
const PHONE_CHARS_REGEX = /^\+?[\d\s()./-]+$/;
// E.164: "+", a country code that doesn't start with 0, 8-15 digits in all.
const E164_REGEX = /^\+[1-9]\d{7,14}$/;
// What follows +381: a mobile number (6x + 6-7 digits) or a landline
// (area code 1x-3x + 6-7 digits) - 8 or 9 digits, without the trunk 0.
const SERBIAN_NATIONAL_REGEX = /^(?:6\d{7,8}|[1-3]\d{7,8})$/;

const PHONE_ERROR =
  "Unesite ispravan broj telefona, na primer 060 123 4567 ili +381 60 123 4567.";

// Turns what people actually type (060 123 4567, 011/123-4567,
// +381 (0)60 1234567, 00381601234567, +49 30 1234567) into canonical E.164,
// or null when it isn't a plausible number. A number with no country code must
// start with 0 and is read as Serbian (the trunk prefix), since the app is
// Serbian; anything else needs an explicit "+" or "00" country code. Serbian
// numbers are held to Serbian mobile/landline shapes, others to E.164.
export function normalizePhone(raw: string): string | null {
  const trimmed = raw.trim();
  if (!PHONE_CHARS_REGEX.test(trimmed)) return null;

  const digits = trimmed.replace(/\D/g, "");
  let e164: string;
  if (trimmed.startsWith("+")) {
    e164 = `+${digits}`;
  } else if (digits.startsWith("00")) {
    e164 = `+${digits.slice(2)}`;
  } else if (digits.startsWith("0")) {
    e164 = `+381${digits.slice(1)}`;
  } else {
    return null;
  }

  // "+381 (0) 60 ..." - the trunk 0 written out inside an international number.
  if (e164.startsWith("+3810")) e164 = `+381${e164.slice(5)}`;

  if (!E164_REGEX.test(e164)) return null;
  if (e164.startsWith("+381") && !SERBIAN_NATIONAL_REGEX.test(e164.slice(4))) return null;
  return e164;
}

export function validatePhone(raw: string): Validated {
  if (raw.trim().length === 0) return { ok: false, error: "Broj telefona je obavezan." };
  const value = normalizePhone(raw);
  return value ? { ok: true, value } : { ok: false, error: PHONE_ERROR };
}

// --- Password ------------------------------------------------------------

export const PASSWORD_MIN_LENGTH = 6;
// Supabase Auth (bcrypt) ignores anything past 72 bytes; refusing it beats
// silently truncating what the user thinks they set.
export const PASSWORD_MAX_LENGTH = 72;

export function validateNewPassword(raw: string): Validated {
  if (raw.length < PASSWORD_MIN_LENGTH) {
    return { ok: false, error: `Lozinka mora imati najmanje ${PASSWORD_MIN_LENGTH} znakova.` };
  }
  if (new TextEncoder().encode(raw).length > PASSWORD_MAX_LENGTH) {
    return { ok: false, error: `Lozinka može imati najviše ${PASSWORD_MAX_LENGTH} znakova.` };
  }
  return { ok: true, value: raw };
}

// The repeat-password check, shared by signup and the account form so both say
// the same thing. null when they match.
export function validatePasswordConfirmation(password: string, confirmation: string): string | null {
  if (confirmation.length === 0) return "Ponovite lozinku.";
  return password === confirmation ? null : "Lozinke se ne poklapaju.";
}

// --- Account form --------------------------------------------------------

export type AccountFields = { firstName: string; lastName: string; email: string; phone: string };

export type AccountFormInput = AccountFields & {
  newPassword: string;
  confirmNewPassword: string;
  currentPassword: string;
};

export type AccountFieldName = keyof AccountFormInput;
export type AccountFieldErrors = Partial<Record<AccountFieldName, string>>;

export type AccountChanges = {
  name: boolean;
  email: boolean;
  phone: boolean;
  password: boolean;
  // Email, phone and password are what the current password guards.
  needsCurrentPassword: boolean;
};

// A field counts as unchanged if it is identical to what's stored, or - for
// email and phone - normalizes to the same thing ("060 123 4567" vs the stored
// "0601234567"). Unchanged fields are never validated, so an account that
// predates these rules (an "a@a" email, a "555-0031" phone) can still edit its
// name without being told its untouched phone number is wrong.
export function accountChanges(initial: AccountFields, next: AccountFormInput): AccountChanges {
  const same = (a: string, b: string, normalize: (value: string) => string | null) =>
    a.trim() === b.trim() || (normalize(a) !== null && normalize(a) === normalize(b));

  const email = !same(initial.email, next.email, (value) => {
    const result = validateEmail(value);
    return result.ok ? result.value : null;
  });
  const phone = !same(initial.phone, next.phone, normalizePhone);
  const name =
    initial.firstName.trim() !== next.firstName.trim().replace(/\s+/g, " ") ||
    initial.lastName.trim() !== next.lastName.trim().replace(/\s+/g, " ");
  const password = next.newPassword.length > 0;

  return { name, email, phone, password, needsCurrentPassword: email || phone || password };
}

export type ValidatedAccount =
  | {
      ok: true;
      values: { firstName: string; lastName: string; email: string; phone: string };
      changes: AccountChanges;
    }
  | { ok: false; errors: AccountFieldErrors };

// Validates only what changed (see accountChanges) and hands back the
// normalized values. The current password is checked for presence here; whether
// it is *correct* is the server's business.
export function validateAccountForm(initial: AccountFields, next: AccountFormInput): ValidatedAccount {
  const changes = accountChanges(initial, next);
  const errors: AccountFieldErrors = {};
  const values = { ...initial };

  const firstChanged = initial.firstName.trim() !== next.firstName.trim().replace(/\s+/g, " ");
  if (firstChanged) {
    const result = validateName(next.firstName, "Ime");
    if (result.ok) values.firstName = result.value;
    else errors.firstName = result.error;
  }

  const lastChanged = initial.lastName.trim() !== next.lastName.trim().replace(/\s+/g, " ");
  if (lastChanged) {
    const result = validateName(next.lastName, "Prezime");
    if (result.ok) values.lastName = result.value;
    else errors.lastName = result.error;
  }

  if (changes.email) {
    const result = validateEmail(next.email);
    if (result.ok) values.email = result.value;
    else errors.email = result.error;
  }

  if (changes.phone) {
    const result = validatePhone(next.phone);
    if (result.ok) values.phone = result.value;
    else errors.phone = result.error;
  }

  if (changes.password) {
    const result = validateNewPassword(next.newPassword);
    if (!result.ok) errors.newPassword = result.error;
    else {
      const mismatch = validatePasswordConfirmation(next.newPassword, next.confirmNewPassword);
      if (mismatch) errors.confirmNewPassword = mismatch;
    }
  }

  if (changes.needsCurrentPassword && next.currentPassword.length === 0) {
    errors.currentPassword = "Unesite trenutnu lozinku da biste potvrdili izmenu.";
  }

  if (Object.keys(errors).length > 0) return { ok: false, errors };
  return { ok: true, values, changes };
}
