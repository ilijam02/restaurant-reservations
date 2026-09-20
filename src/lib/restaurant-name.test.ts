import { describe, expect, it } from "vitest";
import { isRestaurantNameTaken } from "./restaurant-name";

describe("isRestaurantNameTaken", () => {
  it("recognises the name index's unique violation", () => {
    expect(
      isRestaurantNameTaken({
        code: "23505",
        message: 'duplicate key value violates unique constraint "restaurants_live_name_unique_idx"',
      }),
    ).toBe(true);
  });

  it("ignores a unique violation on some other constraint", () => {
    expect(isRestaurantNameTaken({ code: "23505", message: 'duplicate key value violates unique constraint "layouts_name_key"' })).toBe(false);
  });

  it("ignores other error codes, even when the message mentions the index", () => {
    expect(isRestaurantNameTaken({ code: "23514", message: "restaurants_live_name_unique_idx" })).toBe(false);
  });

  it("is false when there is no error", () => {
    expect(isRestaurantNameTaken(null)).toBe(false);
    expect(isRestaurantNameTaken(undefined)).toBe(false);
  });
});
