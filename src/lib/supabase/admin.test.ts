import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// vi.mock is hoisted above the imports, so what its factory uses has to be too.
const { updateUserById, createClient } = vi.hoisted(() => {
  const updateUserById = vi.fn();
  return { updateUserById, createClient: vi.fn(() => ({ auth: { admin: { updateUserById } } })) };
});
vi.mock("@supabase/supabase-js", () => ({ createClient }));

import { updateUserEmailAsAdmin } from "./admin";

describe("updateUserEmailAsAdmin", () => {
  beforeEach(() => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-key");
    updateUserById.mockReset();
    createClient.mockClear();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("reports itself unavailable, without contacting Supabase, when the key isn't configured", async () => {
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "");
    expect(await updateUserEmailAsAdmin("user-1", { email: "a@b.rs" })).toEqual({ ok: false, unavailable: true });
    expect(createClient).not.toHaveBeenCalled();
  });

  it("changes the email as already confirmed, so Auth sends no message", async () => {
    updateUserById.mockResolvedValue({ error: null });
    expect(await updateUserEmailAsAdmin("user-1", { email: "a@b.rs" })).toEqual({ ok: true });
    expect(updateUserById).toHaveBeenCalledWith("user-1", { email: "a@b.rs", email_confirm: true });
  });

  it("changes the password in the same call when given one", async () => {
    updateUserById.mockResolvedValue({ error: null });
    await updateUserEmailAsAdmin("user-1", { email: "a@b.rs", password: "novaLozinka1" });
    expect(updateUserById).toHaveBeenCalledWith("user-1", {
      email: "a@b.rs",
      email_confirm: true,
      password: "novaLozinka1",
    });
  });

  it("passes Auth's error code back", async () => {
    updateUserById.mockResolvedValue({ error: { code: "email_exists", status: 422 } });
    expect(await updateUserEmailAsAdmin("user-1", { email: "a@b.rs" })).toEqual({
      ok: false,
      error: { code: "email_exists", status: 422 },
    });
  });

  it("uses a client that keeps no session", async () => {
    updateUserById.mockResolvedValue({ error: null });
    await updateUserEmailAsAdmin("user-1", { email: "a@b.rs" });
    expect(createClient).toHaveBeenCalledWith("https://example.supabase.co", "service-key", {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
  });
});
