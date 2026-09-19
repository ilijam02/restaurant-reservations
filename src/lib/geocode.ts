// Address -> coordinates via the public Nominatim (OpenStreetMap) server.
//
// Its usage policy (operations.osmfoundation.org/policies/nominatim/) shapes
// how this may be used: at most 1 request/second, an identifying User-Agent,
// results cached, and NO search-as-you-type. So this is only ever called from
// an explicit "Pronađi na mapi" click by an owner (rare), from the server so
// the User-Agent is ours, and the result is saved on the restaurant row - which
// is the cache. Not suitable for anything customer-facing or bulk; if that's
// ever needed, use a hosted geocoder or self-host Nominatim instead.

export type GeocodeResult = { latitude: number; longitude: number };
export type GeocodeOutcome = { ok: true; result: GeocodeResult } | { ok: false; error: "not_found" | "unavailable" };

const NOMINATIM_SEARCH_URL = "https://nominatim.openstreetmap.org/search";
// The UI is Serbian-only, so bias results to Serbia: a bare "Knez Mihailova 1"
// would otherwise be free to match a street of the same name abroad.
const COUNTRY_CODES = "rs";

export function isValidCoordinate(latitude: number, longitude: number): boolean {
  return (
    Number.isFinite(latitude) &&
    Number.isFinite(longitude) &&
    latitude >= -90 &&
    latitude <= 90 &&
    longitude >= -180 &&
    longitude <= 180
  );
}

// Number(null) and Number("") are 0 - a missing coordinate must not turn into
// a pin off the coast of Africa, so only real strings/numbers are converted.
function toCoordinate(value: unknown): number {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim() !== "") return Number(value);
  return Number.NaN;
}

// Nominatim returns an array of matches, best first, with lat/lon as strings.
// Returns the first usable one, or null for no match or a malformed body.
export function parseGeocodeResponse(body: unknown): GeocodeResult | null {
  if (!Array.isArray(body)) return null;
  for (const entry of body) {
    if (typeof entry !== "object" || entry === null) continue;
    const latitude = toCoordinate((entry as { lat?: unknown }).lat);
    const longitude = toCoordinate((entry as { lon?: unknown }).lon);
    if (isValidCoordinate(latitude, longitude)) return { latitude, longitude };
  }
  return null;
}

export function buildGeocodeUrl(address: string): string {
  const params = new URLSearchParams({
    q: address.trim(),
    format: "jsonv2",
    limit: "1",
    countrycodes: COUNTRY_CODES,
  });
  return `${NOMINATIM_SEARCH_URL}?${params}`;
}

export async function geocodeAddress(
  address: string,
  userAgent: string,
  fetchImpl: typeof fetch = fetch,
): Promise<GeocodeOutcome> {
  try {
    const response = await fetchImpl(buildGeocodeUrl(address), {
      // No Accept-Language on purpose: Serbian addresses are mapped in both
      // scripts, and asking for Latin ("sr-Latn") ranks a same-named village
      // street above the Cyrillic-named one in central Belgrade - "Knez
      // Mihailova 1, Beograd" resolved to Rabrovac (Mladenovac).
      headers: { "User-Agent": userAgent },
      // Never reuse another caller's cached response for a different session.
      cache: "no-store",
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) return { ok: false, error: "unavailable" };
    const result = parseGeocodeResponse(await response.json());
    return result ? { ok: true, result } : { ok: false, error: "not_found" };
  } catch {
    return { ok: false, error: "unavailable" };
  }
}
