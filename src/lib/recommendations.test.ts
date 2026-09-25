import { describe, expect, it } from "vitest";
import { describeOrdering, rankRestaurants, type Recommendation } from "./recommendations";

const rec = (over: Partial<Recommendation> & { restaurant_id: string; rank: number }): Recommendation => ({
  personalization: 0,
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

describe("describeOrdering", () => {
  it("explains a purely popularity-based order", () => {
    expect(describeOrdering([rec({ restaurant_id: "a", rank: 1, personalization: 0 })])).toMatch(/^Redosled prema popularnosti/);
  });

  it("reports the personalization as a rounded percentage", () => {
    expect(describeOrdering([rec({ restaurant_id: "a", rank: 1, personalization: 0.8347 })])).toBe(
      "Redosled: 83% prilagođeno vama, ostatak prema popularnosti.",
    );
    expect(describeOrdering([rec({ restaurant_id: "a", rank: 1, personalization: 0.667 })])).toBe(
      "Redosled: 67% prilagođeno vama, ostatak prema popularnosti.",
    );
  });

  it("says nothing without a ranking", () => {
    expect(describeOrdering(null)).toBeNull();
    expect(describeOrdering([])).toBeNull();
  });
});
