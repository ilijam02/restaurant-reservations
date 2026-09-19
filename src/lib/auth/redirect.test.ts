import { describe, expect, it } from "vitest";
import { decideRedirect } from "./redirect";

describe("decideRedirect", () => {
  it("sends anonymous visitors from role home pages to /login", () => {
    expect(decideRedirect("/customer", null)).toBe("/login");
    expect(decideRedirect("/employee", null)).toBe("/login");
    expect(decideRedirect("/owner", null)).toBe("/login");
  });

  it("lets anonymous visitors stay on /login and /signup", () => {
    expect(decideRedirect("/login", null)).toBeNull();
    expect(decideRedirect("/signup", null)).toBeNull();
  });

  it("sends anonymous visitors from / to /login", () => {
    expect(decideRedirect("/", null)).toBe("/login");
  });

  it("sends authenticated users away from /login, /signup, and / to their home page", () => {
    expect(decideRedirect("/login", "customer")).toBe("/customer");
    expect(decideRedirect("/signup", "employee")).toBe("/employee");
    expect(decideRedirect("/", "owner")).toBe("/owner");
  });

  it("lets authenticated users stay on their own home page", () => {
    expect(decideRedirect("/customer", "customer")).toBeNull();
    expect(decideRedirect("/employee", "employee")).toBeNull();
    expect(decideRedirect("/owner", "owner")).toBeNull();
  });

  it("sends authenticated users away from another role's home page", () => {
    expect(decideRedirect("/owner", "customer")).toBe("/customer");
    expect(decideRedirect("/customer", "employee")).toBe("/employee");
  });

  it("sends anonymous visitors from nested role pages to /login", () => {
    expect(decideRedirect("/owner/reservations", null)).toBe("/login");
    expect(decideRedirect("/owner/restaurants/abc/edit", null)).toBe("/login");
    expect(decideRedirect("/customer/restaurants/abc/reserve", null)).toBe("/login");
    expect(decideRedirect("/employee/apply", null)).toBe("/login");
  });

  it("lets users through to nested pages of their own role", () => {
    expect(decideRedirect("/owner/restaurants/abc/staff", "owner")).toBeNull();
    expect(decideRedirect("/customer/reservations", "customer")).toBeNull();
    expect(decideRedirect("/employee/restaurants/abc", "employee")).toBeNull();
  });

  it("sends users away from another role's nested pages to their own home", () => {
    expect(decideRedirect("/owner/restaurants/abc/edit", "customer")).toBe("/customer");
    expect(decideRedirect("/owner/reservations", "employee")).toBe("/employee");
    expect(decideRedirect("/customer/restaurants/abc/reserve", "owner")).toBe("/owner");
    expect(decideRedirect("/employee/apply", "customer")).toBe("/customer");
  });

  it("matches whole path segments only", () => {
    expect(decideRedirect("/owners", null)).toBeNull();
    expect(decideRedirect("/customer-support", "owner")).toBeNull();
    expect(decideRedirect("/employeeX/apply", "customer")).toBeNull();
  });

  it("sees through percent-encoded role prefixes", () => {
    expect(decideRedirect("/%6Fwner/reservations", null)).toBe("/login");
    expect(decideRedirect("/%6fwner", "customer")).toBe("/customer");
    expect(decideRedirect("/customer/%72eservations", "owner")).toBe("/owner");
    expect(decideRedirect("/%6Fwner/reservations", "owner")).toBeNull();
    expect(decideRedirect("/%6Cogin", "owner")).toBe("/owner");
    // An encoded slash decodes to a real one, so it's still under the role.
    expect(decideRedirect("/owner%2Freservations", "customer")).toBe("/customer");
  });

  it("fails closed on malformed percent-encoding", () => {
    expect(decideRedirect("/owner/%E0%A4%A", null)).toBe("/login");
    expect(decideRedirect("/%", "customer")).toBe("/customer");
  });

  it("leaves unrelated paths alone", () => {
    expect(decideRedirect("/some-other-page", null)).toBeNull();
    expect(decideRedirect("/some-other-page", "customer")).toBeNull();
  });
});
