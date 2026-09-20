import { beforeEach, describe, expect, it, vi } from "vitest";

// Everything updateAccountAction talks to is replaced, so these tests pin down
// what it decides: above all that the current password is verified BEFORE the
// service-role email change, that the change is made for the session's user
// and nobody else, and that a failure leaves nothing half-saved.
const mocks = vi.hoisted(() => {
  const profile = { first_name: "Ana", last_name: "Anić", phone: "0601234567" };
  const profileUpdateEq = vi.fn();
  const profileUpdate = vi.fn(() => ({ eq: profileUpdateEq }));
  const getUser = vi.fn();
  const verifierUpdateUser = vi.fn();
  return {
    profile,
    getUser,
    profileUpdate,
    profileUpdateEq,
    verifierUpdateUser,
    verifier: { auth: { updateUser: verifierUpdateUser } },
    verifyPassword: vi.fn(),
    releaseVerifier: vi.fn(),
    updateUserEmailAsAdmin: vi.fn(),
    supabase: {
      auth: { getUser },
      from: vi.fn(() => ({
        select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: profile, error: null }) }) }),
        update: profileUpdate,
      })),
    },
  };
});

vi.mock("@/lib/supabase/server", () => ({ createClient: async () => mocks.supabase }));
vi.mock("@/lib/auth/verify-password", () => ({
  verifyPassword: mocks.verifyPassword,
  releaseVerifier: mocks.releaseVerifier,
}));
vi.mock("@/lib/supabase/admin", () => ({ updateUserEmailAsAdmin: mocks.updateUserEmailAsAdmin }));

import { updateAccountAction } from "./update-account";
import type { AccountFormInput } from "@/lib/validation";

const SESSION_USER = { id: "session-user", email: "ana@primer.rs" };

// The form as stored, i.e. "nothing changed"; each test overrides what it edits.
const unchanged: AccountFormInput = {
  firstName: "Ana",
  lastName: "Anić",
  email: "ana@primer.rs",
  phone: "0601234567",
  newPassword: "",
  confirmNewPassword: "",
  currentPassword: "",
};

const submit = (overrides: Partial<AccountFormInput> = {}, extra: Record<string, unknown> = {}) =>
  updateAccountAction({ ...unchanged, ...overrides, ...extra } as AccountFormInput);

describe("updateAccountAction", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getUser.mockResolvedValue({ data: { user: SESSION_USER } });
    mocks.verifyPassword.mockResolvedValue(mocks.verifier);
    mocks.verifierUpdateUser.mockResolvedValue({ data: {}, error: null });
    mocks.updateUserEmailAsAdmin.mockResolvedValue({ ok: true });
    mocks.profileUpdateEq.mockResolvedValue({ error: null });
  });

  describe("the current password gate", () => {
    it("never calls the admin API when the password is wrong", async () => {
      mocks.verifyPassword.mockResolvedValue(null);
      const result = await submit({ email: "nova@primer.rs", currentPassword: "pogresna" });

      expect(result).toEqual({ ok: false, errors: { currentPassword: "Pogrešna lozinka." } });
      expect(mocks.updateUserEmailAsAdmin).not.toHaveBeenCalled();
      expect(mocks.verifierUpdateUser).not.toHaveBeenCalled();
      expect(mocks.profileUpdate).not.toHaveBeenCalled();
    });

    it("never gets as far as the password check, let alone the admin API, when none was typed", async () => {
      const result = await submit({ email: "nova@primer.rs", currentPassword: "" });

      expect(result).toMatchObject({ ok: false, errors: { currentPassword: expect.any(String) } });
      expect(mocks.verifyPassword).not.toHaveBeenCalled();
      expect(mocks.updateUserEmailAsAdmin).not.toHaveBeenCalled();
    });

    it("verifies the password before the admin call, for the session's own email", async () => {
      await submit({ email: "nova@primer.rs", currentPassword: "tajna1" });

      expect(mocks.verifyPassword).toHaveBeenCalledWith(SESSION_USER.email, "tajna1");
      const verifiedAt = mocks.verifyPassword.mock.invocationCallOrder[0];
      const adminAt = mocks.updateUserEmailAsAdmin.mock.invocationCallOrder[0];
      expect(verifiedAt).toBeLessThan(adminAt);
    });

    it("does not ask for the password for a name-only change", async () => {
      const result = await submit({ firstName: "Anja" });

      expect(result).toEqual({ ok: true, message: "Izmene su sačuvane." });
      expect(mocks.verifyPassword).not.toHaveBeenCalled();
      expect(mocks.updateUserEmailAsAdmin).not.toHaveBeenCalled();
      expect(mocks.profileUpdate).toHaveBeenCalledWith({ first_name: "Anja", last_name: "Anić" });
    });

    it("does not treat a re-cased or re-spaced email as a change (so no admin call)", async () => {
      const result = await submit({ email: "  ANA@primer.rs " });

      expect(result).toEqual({ ok: true, message: "Nema izmena za čuvanje." });
      expect(mocks.verifyPassword).not.toHaveBeenCalled();
      expect(mocks.updateUserEmailAsAdmin).not.toHaveBeenCalled();
    });
  });

  describe("who the email change is made for", () => {
    it("uses the session's user id and the normalized email, whatever else the request carries", async () => {
      await submit(
        { email: "  Nova@Primer.RS ", currentPassword: "tajna1" },
        { id: "someone-else", userId: "someone-else", user_id: "someone-else" },
      );

      expect(mocks.updateUserEmailAsAdmin).toHaveBeenCalledTimes(1);
      expect(mocks.updateUserEmailAsAdmin).toHaveBeenCalledWith("session-user", { email: "nova@primer.rs" });
    });

    it("sends a new password in the same admin call, and not through the verifier", async () => {
      await submit({
        email: "nova@primer.rs",
        newPassword: "novaLozinka1",
        confirmNewPassword: "novaLozinka1",
        currentPassword: "tajna1",
      });

      expect(mocks.updateUserEmailAsAdmin).toHaveBeenCalledWith("session-user", {
        email: "nova@primer.rs",
        password: "novaLozinka1",
      });
      expect(mocks.verifierUpdateUser).not.toHaveBeenCalled();
    });

    it("changes a password-only edit through the verifier's session, never the admin API", async () => {
      const result = await submit({
        newPassword: "novaLozinka1",
        confirmNewPassword: "novaLozinka1",
        currentPassword: "tajna1",
      });

      expect(result).toEqual({ ok: true, message: "Izmene su sačuvane." });
      expect(mocks.verifierUpdateUser).toHaveBeenCalledWith({ password: "novaLozinka1" });
      expect(mocks.updateUserEmailAsAdmin).not.toHaveBeenCalled();
    });

    it("does nothing at all when nobody is signed in", async () => {
      mocks.getUser.mockResolvedValue({ data: { user: null } });
      const result = await submit({ email: "nova@primer.rs", currentPassword: "tajna1" });

      expect(result).toMatchObject({ ok: false });
      expect(mocks.verifyPassword).not.toHaveBeenCalled();
      expect(mocks.updateUserEmailAsAdmin).not.toHaveBeenCalled();
      expect(mocks.profileUpdate).not.toHaveBeenCalled();
    });
  });

  describe("failures", () => {
    const emailChange = { email: "nova@primer.rs", firstName: "Anja", phone: "064 555 666", currentPassword: "tajna1" };

    it("saves nothing, not even the name in the same submission, when the service-role key is missing", async () => {
      mocks.updateUserEmailAsAdmin.mockResolvedValue({ ok: false, unavailable: true });
      vi.spyOn(console, "error").mockImplementation(() => {});
      const result = await submit(emailChange);

      expect(result).toEqual({
        ok: false,
        error: "Promena emaila trenutno nije dostupna. Pokušajte ponovo kasnije.",
      });
      expect(mocks.profileUpdate).not.toHaveBeenCalled();
      expect(mocks.releaseVerifier).toHaveBeenCalledTimes(1);
    });

    it("shows an already-registered email under the email field and saves nothing else", async () => {
      mocks.updateUserEmailAsAdmin.mockResolvedValue({ ok: false, error: { code: "email_exists", status: 422 } });
      const result = await submit(emailChange);

      expect(result).toEqual({ ok: false, errors: { email: "Nalog sa ovim emailom već postoji." } });
      expect(mocks.profileUpdate).not.toHaveBeenCalled();
      expect(mocks.releaseVerifier).toHaveBeenCalledTimes(1);
    });

    it("logs an unrecognized Auth error by code and status only, and shows the generic message", async () => {
      const log = vi.spyOn(console, "error").mockImplementation(() => {});
      mocks.updateUserEmailAsAdmin.mockResolvedValue({
        ok: false,
        error: { code: "weird_failure", status: 500, message: 'Email address "nova@primer.rs" is broken' },
      });
      const result = await submit(emailChange);

      expect(result).toEqual({ ok: false, error: "Čuvanje izmena nije uspelo. Pokušajte ponovo." });
      expect(log).toHaveBeenCalledWith(expect.any(String), { code: "weird_failure", status: 500 });
      expect(JSON.stringify(log.mock.calls)).not.toContain("nova@primer.rs");
    });

    it("tells the form to start over when the email changed but the profile write failed", async () => {
      mocks.profileUpdateEq.mockResolvedValue({ error: { message: "db down" } });
      const result = await submit(emailChange);

      expect(mocks.updateUserEmailAsAdmin).toHaveBeenCalledTimes(1);
      expect(result).toMatchObject({ ok: false, authChanged: true });
    });

    it("does not flag authChanged when nothing in Auth had changed yet", async () => {
      mocks.profileUpdateEq.mockResolvedValue({ error: { message: "db down" } });
      const result = await submit({ firstName: "Anja" });

      expect(result).toMatchObject({ ok: false });
      expect(result).not.toHaveProperty("authChanged");
    });
  });
});
