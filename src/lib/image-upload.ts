import type { SupabaseClient } from "@supabase/supabase-js";

export const IMAGE_BUCKET = "restaurant-images";

// Must stay in sync with the bucket's allowed_mime_types in
// supabase/migrations/20260919120000_restaurant_image_storage.sql.
export const ACCEPTED_IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp"];
export const ACCEPT_ATTRIBUTE = ACCEPTED_IMAGE_TYPES.join(",");

// The file the owner picks, before downscaling. Phone photos are routinely
// 3-8 MB; this only rejects the truly oversized/wrong file up front - what's
// actually uploaded is the resized blob, well under the bucket's 5 MiB cap.
const MAX_SOURCE_BYTES = 15 * 1024 * 1024;

export const RESTAURANT_IMAGE_MAX_DIMENSION = 1600;
export const MENU_ITEM_IMAGE_MAX_DIMENSION = 900;

const OUTPUT_QUALITY = 0.85;

export const IMAGE_TYPE_ERROR = "Slika mora biti u JPEG, PNG ili WebP formatu.";
export const IMAGE_TOO_LARGE_ERROR = "Slika je prevelika (najviše 15 MB).";
export const IMAGE_READ_ERROR = "Slika se ne može pročitati. Probajte drugu sliku.";
export const IMAGE_UPLOAD_ERROR = "Otpremanje slike nije uspelo. Pokušajte ponovo.";

// Returns an error message, or null if the file is acceptable.
export function validateImageFile(file: { type: string; size: number }): string | null {
  if (!ACCEPTED_IMAGE_TYPES.includes(file.type)) return IMAGE_TYPE_ERROR;
  if (file.size > MAX_SOURCE_BYTES) return IMAGE_TOO_LARGE_ERROR;
  return null;
}

// Scales (width, height) down so the longer side is at most maxDimension,
// preserving aspect ratio. Never scales up.
export function fitWithin(width: number, height: number, maxDimension: number) {
  const longest = Math.max(width, height);
  if (longest <= maxDimension) return { width, height };
  const scale = maxDimension / longest;
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
}

function canvasToBlob(canvas: HTMLCanvasElement, type: string): Promise<Blob | null> {
  return new Promise((resolve) => canvas.toBlob(resolve, type, OUTPUT_QUALITY));
}

// Downscales in the browser before upload. Output is WebP where the browser
// can encode it (all current ones), JPEG otherwise - the check is on the
// returned blob's type, since toBlob silently falls back to PNG for an
// unsupported type. Returns null if the file can't be decoded as an image.
export async function resizeImage(file: File, maxDimension: number): Promise<Blob | null> {
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch {
    return null;
  }

  const { width, height } = fitWithin(bitmap.width, bitmap.height, maxDimension);
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  if (!context) {
    bitmap.close();
    return null;
  }
  context.drawImage(bitmap, 0, 0, width, height);
  bitmap.close();

  const webp = await canvasToBlob(canvas, "image/webp");
  if (webp && webp.type === "image/webp") return webp;
  return canvasToBlob(canvas, "image/jpeg");
}

function extensionFor(blob: Blob) {
  return blob.type === "image/webp" ? "webp" : "jpg";
}

// Objects are stored at "<restaurant_id>/<random>.<ext>" - the storage RLS
// policies check ownership of the restaurant named by that first segment.
// The random name (rather than a fixed per-item name) means replacing an
// image always produces a new URL, so no browser/CDN cache can keep serving
// the old one.
export async function uploadRestaurantImage(
  supabase: SupabaseClient,
  restaurantId: string,
  blob: Blob,
): Promise<{ url: string } | { error: string }> {
  const path = `${restaurantId}/${crypto.randomUUID()}.${extensionFor(blob)}`;
  const { error } = await supabase.storage.from(IMAGE_BUCKET).upload(path, blob, { contentType: blob.type });
  if (error) return { error: IMAGE_UPLOAD_ERROR };
  return { url: supabase.storage.from(IMAGE_BUCKET).getPublicUrl(path).data.publicUrl };
}

// Recovers the object path from a stored public URL, or null if the URL
// isn't one of this bucket's (e.g. an externally-hosted image_url).
export function pathFromPublicUrl(url: string): string | null {
  const marker = `/storage/v1/object/public/${IMAGE_BUCKET}/`;
  const index = url.indexOf(marker);
  if (index === -1) return null;
  return decodeURIComponent(url.slice(index + marker.length).split("?")[0]);
}

// Best-effort cleanup of an image that's no longer referenced. A failure
// here just leaves an orphaned object - never worth failing a save over.
export async function removeStoredImage(supabase: SupabaseClient, url: string | null | undefined) {
  if (!url) return;
  const path = pathFromPublicUrl(url);
  if (!path) return;
  await supabase.storage.from(IMAGE_BUCKET).remove([path]);
}
