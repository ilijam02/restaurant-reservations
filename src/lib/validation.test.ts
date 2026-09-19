import { describe, expect, it } from "vitest";
import {
  accountChanges,
  normalizePhone,
  validateAccountForm,
  validateEmail,
  validateName,
  validateNewPassword,
  validatePasswordConfirmation,
  validatePhone,
  type AccountFields,
  type AccountFormInput,
} from "./validation";

describe("validateEmail", () => {
  it("accepts ordinary addresses and normalizes case and surrounding space", () => {
    expect(validateEmail("  Ime.Prezime+rezervacije@Mail.Example.rs ")).toEqual({
      ok: true,
      value: "ime.prezime+rezervacije@mail.example.rs",
    });
    expect(validateEmail("a@b.co")).toEqual({ ok: true, value: "a@b.co" });
    expect(validateEmail("x@xn--80ak6aa92e.com").ok).toBe(true);
  });

  it("rejects what the browser's type=email lets through", () => {
    for (const bad of ["a@a", "asfasf@f", "name@localhost", "x@y.1", "x@y.c", "name@domain"]) {
      expect(validateEmail(bad).ok, bad).toBe(false);
    }
  });

  it("needs one or more letters, digits, hyphens or dots after the @, then a dot and a TLD of 2+ letters", () => {
    const good = [
      "a@b.co",
      "a@b.com",
      "a@my-shop.rs",
      "a@shop24.rs",
      "a@mail.my-shop.example.rs", // dots inside the part before the TLD
      "a@123.rs",
      "a@b.museum", // long TLD
    ];
    for (const value of good) expect(validateEmail(value).ok, value).toBe(true);

    const bad = [
      "a@.rs", // nothing before the dot
      "a@b.c", // TLD of one character
      "a@b.", // no TLD at all
      "a@b", // no dot
      "a@b.c0m", // digit in the TLD
      "a@b.r-s", // hyphen in the TLD
      "a@b_c.rs", // underscore in the domain
      "a@b c.rs",
      "a@b.rs/x",
    ];
    for (const value of bad) expect(validateEmail(value).ok, value).toBe(false);
  });

  it("rejects malformed local parts and domains", () => {
    const bad = [
      "",
      "plain",
      "@domain.rs",
      "name@",
      "a@@b.rs",
      "a b@c.rs",
      ".a@b.rs",
      "a.@b.rs",
      "a..b@c.rs",
      "a@-b.rs",
      "a@b-.rs",
      "a@b..rs",
      "a@.rs",
      "a@b.rs.",
      "a@[127.0.0.1]",
      "\"quoted\"@b.rs",
      "a,b@c.rs",
      "šara@b.rs",
    ];
    for (const value of bad) expect(validateEmail(value).ok, value).toBe(false);
  });

  it("enforces the length limits", () => {
    expect(validateEmail(`${"a".repeat(64)}@b.rs`).ok).toBe(true);
    expect(validateEmail(`${"a".repeat(65)}@b.rs`).ok).toBe(false);
    expect(validateEmail(`a@${"b".repeat(64)}.rs`).ok).toBe(false);
    expect(validateEmail(`a@${"b.".repeat(130)}rs`).ok).toBe(false);
  });

  it("says the field is required when it is empty", () => {
    expect(validateEmail("   ")).toEqual({ ok: false, error: "Email je obavezan." });
  });
});

describe("validatePasswordConfirmation", () => {
  it("passes when both match", () => {
    expect(validatePasswordConfirmation("abcdef", "abcdef")).toBeNull();
  });

  it("asks to repeat when the repeat is empty, and reports a mismatch otherwise", () => {
    expect(validatePasswordConfirmation("abcdef", "")).toBe("Ponovite lozinku.");
    expect(validatePasswordConfirmation("abcdef", "abcdeg")).toBe("Lozinke se ne poklapaju.");
    expect(validatePasswordConfirmation("abcdef", "ABCDEF")).toBe("Lozinke se ne poklapaju.");
  });
});

describe("normalizePhone", () => {
  it("reads a leading 0 as Serbian and writes E.164", () => {
    expect(normalizePhone("060 123 4567")).toBe("+381601234567");
    expect(normalizePhone("0601234567")).toBe("+381601234567");
    expect(normalizePhone("064/123-456")).toBe("+38164123456");
    expect(normalizePhone("011/123-4567")).toBe("+381111234567");
    expect(normalizePhone("(021) 123 456")).toBe("+38121123456");
  });

  it("accepts Serbian numbers written internationally", () => {
    expect(normalizePhone("+381 60 123 4567")).toBe("+381601234567");
    expect(normalizePhone("+381601234567")).toBe("+381601234567");
    expect(normalizePhone("00381 60 1234567")).toBe("+381601234567");
    expect(normalizePhone("+381 (0) 60 1234567")).toBe("+381601234567");
    expect(normalizePhone("+381-11-123-4567")).toBe("+381111234567");
  });

  it("accepts other international numbers", () => {
    expect(normalizePhone("+49 30 12345678")).toBe("+493012345678");
    expect(normalizePhone("0044 20 7946 0958")).toBe("+442079460958");
    expect(normalizePhone("+1 (415) 555-2671")).toBe("+14155552671");
  });

  it("rejects numbers with no country code and no leading 0", () => {
    expect(normalizePhone("601234567")).toBeNull();
    expect(normalizePhone("123456789")).toBeNull();
  });

  it("rejects Serbian numbers with the wrong shape", () => {
    expect(normalizePhone("0601234")).toBeNull(); // too short
    expect(normalizePhone("060123456789")).toBeNull(); // too long
    expect(normalizePhone("0501234567")).toBeNull(); // no such prefix
    expect(normalizePhone("+381 40 1234567")).toBeNull();
    expect(normalizePhone("0800 123 456")).toBeNull(); // not a mobile/landline
  });

  it("rejects junk", () => {
    for (const bad of ["", "abc", "060-abc-4567", "+", "++381601234567", "060 123 4567 ext 2", "555-0031", "1", "0"]) {
      expect(normalizePhone(bad), bad).toBeNull();
    }
    expect(normalizePhone("060+1234567")).toBeNull(); // + only at the start
    expect(normalizePhone("+0601234567")).toBeNull(); // country code can't start with 0
    expect(normalizePhone(`+${"9".repeat(16)}`)).toBeNull(); // over 15 digits
  });
});

describe("validatePhone", () => {
  it("returns the normalized number", () => {
    expect(validatePhone(" 060 123 4567 ")).toEqual({ ok: true, value: "+381601234567" });
  });

  it("distinguishes empty from malformed", () => {
    expect(validatePhone("")).toEqual({ ok: false, error: "Broj telefona je obavezan." });
    expect(validatePhone("12").ok).toBe(false);
  });
});

describe("validateName", () => {
  it("accepts names in Latin and Cyrillic with the usual punctuation", () => {
    for (const good of ["Ana", "Đorđe", "Јована", "Ana Marija", "Jovanović-Petrović", "O'Brien", "O’Brien", "St. John"]) {
      expect(validateName(good, "Ime").ok, good).toBe(true);
    }
  });

  it("trims and collapses whitespace", () => {
    expect(validateName("  Ana   Marija ", "Ime")).toEqual({ ok: true, value: "Ana Marija" });
  });

  it("rejects blank, digits, symbols and leftover punctuation", () => {
    expect(validateName("   ", "Ime")).toEqual({ ok: false, error: "Ime je obavezno." });
    expect(validateName("", "Prezime")).toEqual({ ok: false, error: "Prezime je obavezno." });
    for (const bad of ["Ana2", "R2-D2", "Ana@", "-Ana", "Ana-", "Ana--Marija", "<b>Ana</b>", "Ana_"]) {
      expect(validateName(bad, "Ime").ok, bad).toBe(false);
    }
  });

  it("caps the length", () => {
    expect(validateName("A".repeat(50), "Ime").ok).toBe(true);
    expect(validateName("A".repeat(51), "Ime").ok).toBe(false);
  });
});

describe("validateNewPassword", () => {
  it("needs at least 6 characters and at most 72 bytes", () => {
    expect(validateNewPassword("12345").ok).toBe(false);
    expect(validateNewPassword("123456").ok).toBe(true);
    expect(validateNewPassword("a".repeat(72)).ok).toBe(true);
    expect(validateNewPassword("a".repeat(73)).ok).toBe(false);
    // 40 two-byte characters is 80 bytes.
    expect(validateNewPassword("š".repeat(40)).ok).toBe(false);
  });
});

const initial: AccountFields = {
  firstName: "Ana",
  lastName: "Anić",
  email: "ana@primer.rs",
  phone: "0601234567",
};

const unchanged: AccountFormInput = { ...initial, newPassword: "", confirmNewPassword: "", currentPassword: "" };

describe("accountChanges", () => {
  it("sees nothing changed when nothing changed", () => {
    expect(accountChanges(initial, unchanged)).toEqual({
      name: false,
      email: false,
      phone: false,
      password: false,
      needsCurrentPassword: false,
    });
  });

  it("does not count a reformatted-but-identical phone or a re-cased email", () => {
    const changes = accountChanges(initial, { ...unchanged, phone: "+381 60 123 4567", email: " ANA@primer.rs " });
    expect(changes.phone).toBe(false);
    expect(changes.email).toBe(false);
    expect(changes.needsCurrentPassword).toBe(false);
  });

  it("needs the current password for email, phone or password, but not for a name", () => {
    expect(accountChanges(initial, { ...unchanged, firstName: "Anja" })).toMatchObject({
      name: true,
      needsCurrentPassword: false,
    });
    expect(accountChanges(initial, { ...unchanged, email: "nova@primer.rs" }).needsCurrentPassword).toBe(true);
    expect(accountChanges(initial, { ...unchanged, phone: "064 555 666" }).needsCurrentPassword).toBe(true);
    expect(accountChanges(initial, { ...unchanged, newPassword: "abcdef" }).needsCurrentPassword).toBe(true);
  });
});

describe("validateAccountForm", () => {
  it("accepts an untouched form", () => {
    const result = validateAccountForm(initial, unchanged);
    expect(result.ok).toBe(true);
  });

  it("lets a name change through on an account whose email and phone predate the rules", () => {
    const legacy: AccountFields = { ...initial, email: "a@a", phone: "555-0031" };
    const result = validateAccountForm(legacy, { ...legacy, newPassword: "", confirmNewPassword: "", currentPassword: "", firstName: "Anja" });
    expect(result).toMatchObject({ ok: true, values: { firstName: "Anja", email: "a@a", phone: "555-0031" } });
  });

  it("returns normalized values for what changed", () => {
    const result = validateAccountForm(initial, {
      ...unchanged,
      firstName: "  Anja ",
      email: "NOVA@Primer.rs",
      phone: "064 555 666",
      currentPassword: "tajna1",
    });
    expect(result).toMatchObject({
      ok: true,
      values: { firstName: "Anja", lastName: "Anić", email: "nova@primer.rs", phone: "+38164555666" },
      changes: { name: true, email: true, phone: true, password: false, needsCurrentPassword: true },
    });
  });

  it("reports every bad field at once", () => {
    const result = validateAccountForm(initial, {
      firstName: "",
      lastName: "Anić2",
      email: "a@a",
      phone: "12",
      newPassword: "abc",
      confirmNewPassword: "abc",
      currentPassword: "",
    });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(Object.keys(result.errors).sort()).toEqual(
        ["currentPassword", "email", "firstName", "lastName", "newPassword", "phone"].sort(),
      );
    }
  });

  it("requires the current password for a sensitive change", () => {
    const result = validateAccountForm(initial, { ...unchanged, email: "nova@primer.rs" });
    expect(result).toEqual({
      ok: false,
      errors: { currentPassword: "Unesite trenutnu lozinku da biste potvrdili izmenu." },
    });
  });

  it("checks the two new passwords match", () => {
    const result = validateAccountForm(initial, {
      ...unchanged,
      newPassword: "abcdef",
      confirmNewPassword: "abcdeg",
      currentPassword: "tajna1",
    });
    expect(result).toEqual({ ok: false, errors: { confirmNewPassword: "Lozinke se ne poklapaju." } });
  });
});
