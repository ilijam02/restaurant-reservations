import { describe, expect, it } from "vitest";
import {
  IMAGE_TOO_LARGE_ERROR,
  IMAGE_TYPE_ERROR,
  fitWithin,
  pathFromPublicUrl,
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
