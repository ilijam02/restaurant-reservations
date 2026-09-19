import { describe, expect, it } from "vitest";
import { isCurrentPage, menuItemsForPath } from "./nav";

describe("menuItemsForPath", () => {
  it("always lists Početna first, pointing at the role's home page", () => {
    expect(menuItemsForPath("/customer")[0]).toEqual({ label: "Početna", href: "/customer" });
    expect(menuItemsForPath("/employee")[0]).toEqual({ label: "Početna", href: "/employee" });
    expect(menuItemsForPath("/owner")[0]).toEqual({ label: "Početna", href: "/owner" });
  });

  it("gives every page of a role the same items, including nested pages", () => {
    const home = menuItemsForPath("/owner");
    expect(menuItemsForPath("/owner/reservations")).toEqual(home);
    expect(menuItemsForPath("/owner/restaurants/abc/menu")).toEqual(home);
    expect(menuItemsForPath("/customer/restaurants/abc/reserve")).toEqual(menuItemsForPath("/customer"));
    expect(menuItemsForPath("/employee/apply")).toEqual(menuItemsForPath("/employee"));
  });

  it("keeps the current page's own link in the list", () => {
    expect(menuItemsForPath("/customer/reservations").map((i) => i.href)).toContain("/customer/reservations");
    expect(menuItemsForPath("/employee/apply").map((i) => i.href)).toContain("/employee/apply");
    expect(menuItemsForPath("/owner/reservations").map((i) => i.href)).toContain("/owner/reservations");
  });

  it("gives customers a Mapa entry right after Početna", () => {
    expect(menuItemsForPath("/customer")[1]).toEqual({ label: "Mapa", href: "/customer/map" });
  });

  it("has no items outside a role's pages", () => {
    expect(menuItemsForPath("/login")).toEqual([]);
    expect(menuItemsForPath("/")).toEqual([]);
    expect(menuItemsForPath("/ownership")).toEqual([]);
  });
});

describe("isCurrentPage", () => {
  it("matches the same path, ignoring a trailing slash", () => {
    expect(isCurrentPage("/owner", "/owner")).toBe(true);
    expect(isCurrentPage("/owner/", "/owner")).toBe(true);
  });

  it("does not match a parent or child path", () => {
    expect(isCurrentPage("/owner/reservations", "/owner")).toBe(false);
    expect(isCurrentPage("/owner", "/owner/reservations")).toBe(false);
  });
});
