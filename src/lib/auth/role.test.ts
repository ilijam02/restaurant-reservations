import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { getProfileRole } from "./role";

// Just enough of the query builder for
// from("profiles").select("role").eq("id", ...).maybeSingle().
function stubClient(result: { data: unknown; error: { message: string } | null }) {
  return {
    from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => result }) }) }),
  } as unknown as SupabaseClient;
}

describe("getProfileRole", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("returns the role stored on the profile", async () => {
    for (const role of ["customer", "employee", "owner"] as const) {
      expect(await getProfileRole(stubClient({ data: { role }, error: null }), "u1")).toBe(role);
    }
  });

  it("returns null when the user has no profile row", async () => {
    expect(await getProfileRole(stubClient({ data: null, error: null }), "u1")).toBeNull();
  });

  it("returns null for a role value it doesn't know", async () => {
    expect(await getProfileRole(stubClient({ data: { role: "admin" }, error: null }), "u1")).toBeNull();
    expect(await getProfileRole(stubClient({ data: { role: null }, error: null }), "u1")).toBeNull();
  });

  it("fails closed, and logs, when the query errors", async () => {
    const logged = vi.spyOn(console, "error").mockImplementation(() => {});
    const client = stubClient({ data: { role: "owner" }, error: { message: "permission denied" } });

    expect(await getProfileRole(client, "u1")).toBeNull();
    expect(logged).toHaveBeenCalledOnce();
  });
});
