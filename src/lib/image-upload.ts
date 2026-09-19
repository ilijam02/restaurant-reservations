import type { SupabaseClient } from "@supabase/supabase-js";

export const IMAGE_BUCKET = "restaurant-images";

// What an owner may pick. Every browser can decode all three. What actually
// gets uploaded is always a JPEG (see resizeImage), which is within the
// bucket's allowed_mime_types (supabase/migrations/20260919120000_...).
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

// Downscales in the browser before upload and re-encodes as JPEG. JPEG rather
// than WebP because every browser can encode it - some can't encode WebP
// (toBlob then silently returns a PNG), which would need a fallback path.
// JPEG has no transparency, so the canvas is painted white first; otherwise a
// transparent PNG would come out with black regions. Returns null if the file
// can't be decoded as an image.
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
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, width, height);
  context.drawImage(bitmap, 0, 0, width, height);
  bitmap.close();

  return canvasToBlob(canvas, "image/jpeg");
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
  const path = `${restaurantId}/${crypto.randomUUID()}.jpg`;
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
  try {
    return decodeURIComponent(url.slice(index + marker.length).split("?")[0]);
  } catch {
    // A malformed escape sequence in a hand-edited URL.
    return null;
  }
}

// Removes every object in a restaurant's storage folder (its cover and all its
// menu photos). Unlike removeStoredImage this is NOT best-effort: it returns
// false if anything couldn't be removed, so a restaurant deletion can stop
// before the row goes - the storage delete policy checks ownership through the
// restaurants row, so the files can't be cleaned up afterwards.
const FOLDER_PAGE_SIZE = 100;
const MAX_FOLDER_PAGES = 100;

export async function removeRestaurantImageFolder(supabase: SupabaseClient, restaurantId: string): Promise<boolean> {
  try {
    const bucket = supabase.storage.from(IMAGE_BUCKET);
    // Each round removes what it listed, so the next list starts from the top
    // again. The page cap only guards against a remove that reports success
    // while deleting nothing.
    for (let page = 0; page < MAX_FOLDER_PAGES; page++) {
      const { data: objects, error: listError } = await bucket.list(restaurantId, { limit: FOLDER_PAGE_SIZE });
      if (listError) return false;
      if (!objects || objects.length === 0) return true;

      const { data: removed, error: removeError } = await bucket.remove(
        objects.map((object) => `${restaurantId}/${object.name}`),
      );
      if (removeError || !removed || removed.length === 0) return false;
    }
    return false;
  } catch {
    return false;
  }
}

// Best-effort cleanup of an image that's no longer referenced. A failure
// here just leaves an orphaned object - never worth failing a save over, so
// nothing in here is allowed to throw either.
export async function removeStoredImage(supabase: SupabaseClient, url: string | null | undefined) {
  if (!url) return;
  try {
    const path = pathFromPublicUrl(url);
    if (!path) return;
    await supabase.storage.from(IMAGE_BUCKET).remove([path]);
  } catch {
    // Leave the object orphaned.
  }
}
