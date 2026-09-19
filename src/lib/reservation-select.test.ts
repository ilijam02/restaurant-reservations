import { describe, expect, it } from "vitest";
import { OWNER_RESERVATION_LIST_SELECT, RESERVATION_LIST_SELECT } from "./reservation-select";

describe("reservation list selects", () => {
  it("embed the restaurant plainly for the customer's own list", () => {
    expect(RESERVATION_LIST_SELECT).toContain("restaurants(name)");
    expect(RESERVATION_LIST_SELECT).not.toContain("!inner");
  });

  it("embed it with !inner for the owner's lists, so archived restaurants can be filtered out", () => {
    expect(OWNER_RESERVATION_LIST_SELECT).toContain("restaurants!inner(name)");
    expect(OWNER_RESERVATION_LIST_SELECT).not.toContain("restaurants(name)");
  });

  it("are otherwise identical", () => {
    expect(OWNER_RESERVATION_LIST_SELECT.replace("restaurants!inner(name)", "restaurants(name)")).toBe(
      RESERVATION_LIST_SELECT,
    );
  });
});
