import { describe, expect, it } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  IMAGE_TOO_LARGE_ERROR,
  IMAGE_TYPE_ERROR,
  fitWithin,
  pathFromPublicUrl,
  removeRestaurantImageFolder,
  validateImageFile,
} from "./image-upload";

describe("fitWithin", () => {
  it("scales the longer side down to the max, keeping aspect ratio", () => {
    expect(fitWithin(4000, 3000, 1600)).toEqual({ width: 1600, height: 1200 });
    expect(fitWithin(3000, 4000, 1600)).toEqual({ width: 1200, height: 1600 });
  });

  it("never scales up an image that already fits", () => {
    expect(fitWithin(800, 600, 1600)).toEqual({ width: 800, height: 600 });
    expect(fitWithin(1600, 1600, 1600)).toEqual({ width: 1600, height: 1600 });
  });

  it("never rounds a very thin image down to zero", () => {
    expect(fitWithin(10000, 1, 1600).height).toBe(1);
  });
});

describe("validateImageFile", () => {
  it("accepts jpeg, png and webp", () => {
    for (const type of ["image/jpeg", "image/png", "image/webp"]) {
      expect(validateImageFile({ type, size: 1024 })).toBeNull();
    }
  });

  it("rejects other types", () => {
    expect(validateImageFile({ type: "image/gif", size: 1024 })).toBe(IMAGE_TYPE_ERROR);
    expect(validateImageFile({ type: "application/pdf", size: 1024 })).toBe(IMAGE_TYPE_ERROR);
  });

  it("rejects files over 15 MB", () => {
    expect(validateImageFile({ type: "image/jpeg", size: 16 * 1024 * 1024 })).toBe(IMAGE_TOO_LARGE_ERROR);
  });
});

describe("pathFromPublicUrl", () => {
  it("extracts the object path from a bucket public URL", () => {
    expect(
      pathFromPublicUrl("https://abc.supabase.co/storage/v1/object/public/restaurant-images/r1/x.webp"),
    ).toBe("r1/x.webp");
  });

  it("ignores a query string", () => {
    expect(
      pathFromPublicUrl("https://abc.supabase.co/storage/v1/object/public/restaurant-images/r1/x.webp?t=1"),
    ).toBe("r1/x.webp");
  });

  it("returns null instead of throwing on a malformed escape sequence", () => {
    expect(
      pathFromPublicUrl("https://abc.supabase.co/storage/v1/object/public/restaurant-images/r1/%E0%A4%A.jpg"),
    ).toBeNull();
  });

  it("returns null for URLs that aren't in this bucket", () => {
    expect(pathFromPublicUrl("https://example.com/photo.jpg")).toBeNull();
    expect(pathFromPublicUrl("https://abc.supabase.co/storage/v1/object/public/other-bucket/x.webp")).toBeNull();
  });
});

describe("removeRestaurantImageFolder", () => {
  // A fake bucket holding `names` in one folder. `removes` controls whether
  // remove() actually deletes (false = it reports success but deletes nothing).
  function fakeClient(names: string[], { listError = false, removes = true, removeError = false } = {}) {
    let remaining = [...names];
    const removedPaths: string[] = [];
    const client = {
      storage: {
        from: () => ({
          list: async (_folder: string, options: { limit: number }) =>
            listError
              ? { data: null, error: new Error("list failed") }
              : { data: remaining.slice(0, options.limit).map((name) => ({ name })), error: null },
          remove: async (paths: string[]) => {
            if (removeError) return { data: null, error: new Error("remove failed") };
            if (!removes) return { data: [], error: null };
            removedPaths.push(...paths);
            remaining = remaining.filter((name) => !paths.includes(`r1/${name}`));
            return { data: paths.map((name) => ({ name })), error: null };
          },
        }),
      },
    };
    return { client: client as unknown as SupabaseClient, removedPaths };
  }

  it("succeeds on an empty folder without removing anything", async () => {
    const { client, removedPaths } = fakeClient([]);
    expect(await removeRestaurantImageFolder(client, "r1")).toBe(true);
    expect(removedPaths).toEqual([]);
  });

  it("removes every object under the restaurant's folder, across several pages", async () => {
    const names = Array.from({ length: 250 }, (_, i) => `${i}.jpg`);
    const { client, removedPaths } = fakeClient(names);
    expect(await removeRestaurantImageFolder(client, "r1")).toBe(true);
    expect(removedPaths).toEqual(names.map((name) => `r1/${name}`));
  });

  it("reports failure if listing fails", async () => {
    const { client } = fakeClient(["a.jpg"], { listError: true });
    expect(await removeRestaurantImageFolder(client, "r1")).toBe(false);
  });

  it("reports failure if removing fails", async () => {
    const { client } = fakeClient(["a.jpg"], { removeError: true });
    expect(await removeRestaurantImageFolder(client, "r1")).toBe(false);
  });

  it("reports failure instead of looping when remove deletes nothing", async () => {
    const { client } = fakeClient(["a.jpg"], { removes: false });
    expect(await removeRestaurantImageFolder(client, "r1")).toBe(false);
  });
});
