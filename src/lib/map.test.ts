import { describe, expect, it } from "vitest";
import { addressChangedSincePin, mapHrefForRestaurant } from "./map";

describe("addressChangedSincePin", () => {
  it("is false for the same address", () => {
    expect(addressChangedSincePin("Knez Mihailova 1, Beograd", "Knez Mihailova 1, Beograd")).toBe(false);
  });

  it("ignores case and extra whitespace, which don't move a restaurant", () => {
    expect(addressChangedSincePin("  knez   mihailova 1, BEOGRAD ", "Knez Mihailova 1, Beograd")).toBe(false);
  });

  it("is true when the address text really changed", () => {
    expect(addressChangedSincePin("Knez Mihailova 4, Beograd", "Knez Mihailova 1, Beograd")).toBe(true);
    expect(addressChangedSincePin("Terazije 1", "")).toBe(true);
  });

  it("does not treat the letter s as whitespace", () => {
    expect(addressChangedSincePin("Sava 1", "ava 1")).toBe(true);
  });
});

describe("mapHrefForRestaurant", () => {
  it("points the map page at one restaurant", () => {
    expect(mapHrefForRestaurant("abc")).toBe("/customer/map?restaurant=abc");
  });

  it("encodes the id", () => {
    expect(mapHrefForRestaurant("a b&c")).toBe("/customer/map?restaurant=a%20b%26c");
  });
});
