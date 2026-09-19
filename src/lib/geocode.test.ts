import { describe, expect, it, vi } from "vitest";
import { buildGeocodeUrl, geocodeAddress, isValidCoordinate, parseGeocodeResponse } from "./geocode";

describe("isValidCoordinate", () => {
  it("accepts real coordinates, including the range edges", () => {
    expect(isValidCoordinate(44.8, 20.4)).toBe(true);
    expect(isValidCoordinate(-90, 180)).toBe(true);
    expect(isValidCoordinate(0, 0)).toBe(true);
  });

  it("rejects out-of-range and non-finite values", () => {
    expect(isValidCoordinate(91, 0)).toBe(false);
    expect(isValidCoordinate(0, -181)).toBe(false);
    expect(isValidCoordinate(Number.NaN, 0)).toBe(false);
    expect(isValidCoordinate(0, Number.POSITIVE_INFINITY)).toBe(false);
  });
});

describe("parseGeocodeResponse", () => {
  it("reads the string lat/lon of the first match", () => {
    expect(parseGeocodeResponse([{ lat: "44.8206", lon: "20.4573" }, { lat: "1", lon: "1" }])).toEqual({
      latitude: 44.8206,
      longitude: 20.4573,
    });
  });

  it("skips a malformed entry and uses the next usable one", () => {
    expect(parseGeocodeResponse([{ lat: "abc", lon: "20" }, null, { lat: "44", lon: "20" }])).toEqual({
      latitude: 44,
      longitude: 20,
    });
  });

  it("returns null for no match or a body that isn't a list", () => {
    expect(parseGeocodeResponse([])).toBeNull();
    expect(parseGeocodeResponse({ error: "rate limited" })).toBeNull();
    expect(parseGeocodeResponse(null)).toBeNull();
    expect(parseGeocodeResponse([{ lat: "999", lon: "20" }])).toBeNull();
  });

  it("does not treat a missing coordinate as 0", () => {
    expect(parseGeocodeResponse([{ lat: "44.8" }])).toBeNull();
    expect(parseGeocodeResponse([{ lat: null, lon: null }])).toBeNull();
  });
});

describe("buildGeocodeUrl", () => {
  it("encodes the query, limits to one result and restricts to Serbia", () => {
    const url = new URL(buildGeocodeUrl("  Knez Mihailova 1, Beograd  "));
    expect(url.origin + url.pathname).toBe("https://nominatim.openstreetmap.org/search");
    expect(url.searchParams.get("q")).toBe("Knez Mihailova 1, Beograd");
    expect(url.searchParams.get("limit")).toBe("1");
    expect(url.searchParams.get("countrycodes")).toBe("rs");
  });
});

describe("geocodeAddress", () => {
  const jsonResponse = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

  it("sends the identifying User-Agent and returns the coordinates", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse([{ lat: "44.8", lon: "20.4" }]));
    const outcome = await geocodeAddress("Beograd", "TestApp/1.0", fetchMock);
    expect(outcome).toEqual({ ok: true, result: { latitude: 44.8, longitude: 20.4 } });
    expect(fetchMock.mock.calls[0][1].headers["User-Agent"]).toBe("TestApp/1.0");
  });

  it("reports not_found for an empty result", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse([]));
    expect(await geocodeAddress("zzzz", "TestApp/1.0", fetchMock)).toEqual({ ok: false, error: "not_found" });
  });

  it("reports unavailable for an HTTP error (e.g. rate limited) or a network failure", async () => {
    const limited = vi.fn().mockResolvedValue(jsonResponse({}, 429));
    expect(await geocodeAddress("Beograd", "TestApp/1.0", limited)).toEqual({ ok: false, error: "unavailable" });
    const down = vi.fn().mockRejectedValue(new Error("network"));
    expect(await geocodeAddress("Beograd", "TestApp/1.0", down)).toEqual({ ok: false, error: "unavailable" });
  });
});
