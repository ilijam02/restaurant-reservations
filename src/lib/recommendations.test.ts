import { describe, expect, it } from "vitest";
import { describeOrdering, describeRecommendation, rankRestaurants, type Recommendation } from "./recommendations";

const rec = (over: Partial<Recommendation> & { restaurant_id: string; rank: number }): Recommendation => ({
  personalization: 0,
  similar_users: 0,
  booked_before: false,
  popular: false,
  ...over,
});

const restaurants = [
  { id: "a", name: "Alfa" },
  { id: "b", name: "Beta" },
  { id: "c", name: "Gama" },
];

describe("rankRestaurants", () => {
  it("orders by the recommendation rank", () => {
    const recs = [rec({ restaurant_id: "c", rank: 1 }), rec({ restaurant_id: "a", rank: 2 }), rec({ restaurant_id: "b", rank: 3 })];
    expect(rankRestaurants(restaurants, recs).map((r) => r.id)).toEqual(["c", "a", "b"]);
  });

  it("keeps the given (alphabetical) order when there are no recommendations", () => {
    expect(rankRestaurants(restaurants, null)).toBe(restaurants);
    expect(rankRestaurants(restaurants, [])).toBe(restaurants);
  });

  it("puts a restaurant the ranking doesn't know yet last, in its original order", () => {
    const recs = [rec({ restaurant_id: "c", rank: 1 })];
    expect(rankRestaurants(restaurants, recs).map((r) => r.id)).toEqual(["c", "a", "b"]);
  });

  it("does not mutate its input", () => {
    const copy = [...restaurants];
    rankRestaurants(restaurants, [rec({ restaurant_id: "c", rank: 1 })]);
    expect(restaurants).toEqual(copy);
  });
});

describe("describeRecommendation", () => {
  it("says so when the customer has already booked there, before anything else", () => {
    expect(describeRecommendation(rec({ restaurant_id: "a", rank: 1, booked_before: true, similar_users: 3, popular: true }))).toBe(
      "Već ste rezervisali ovde",
    );
  });

  it("counts similar customers with the right Serbian form", () => {
    expect(describeRecommendation(rec({ restaurant_id: "a", rank: 1, similar_users: 1 }))).toBe("Slično vama · 1 korisnik");
    expect(describeRecommendation(rec({ restaurant_id: "a", rank: 1, similar_users: 2 }))).toBe("Slično vama · 2 korisnika");
    expect(describeRecommendation(rec({ restaurant_id: "a", rank: 1, similar_users: 5 }))).toBe("Slično vama · 5 korisnika");
  });

  it("falls back to popularity, then to nothing", () => {
    expect(describeRecommendation(rec({ restaurant_id: "a", rank: 1, popular: true }))).toBe("Popularno");
    expect(describeRecommendation(rec({ restaurant_id: "a", rank: 1 }))).toBeNull();
    expect(describeRecommendation(undefined)).toBeNull();
  });
});

describe("describeOrdering", () => {
  it("explains a purely popularity-based order", () => {
    expect(describeOrdering([rec({ restaurant_id: "a", rank: 1, personalization: 0 })])).toMatch(/^Redosled prema popularnosti/);
  });

  it("reports the personalization as a rounded percentage", () => {
    expect(describeOrdering([rec({ restaurant_id: "a", rank: 1, personalization: 0.8347 })])).toBe(
      "Redosled: 83% prilagođeno vama, ostatak prema popularnosti.",
    );
  });

  it("says nothing without a ranking", () => {
    expect(describeOrdering(null)).toBeNull();
    expect(describeOrdering([])).toBeNull();
  });
});
