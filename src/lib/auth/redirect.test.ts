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

  it("leaves unrelated paths alone", () => {
    expect(decideRedirect("/some-other-page", null)).toBeNull();
    expect(decideRedirect("/some-other-page", "customer")).toBeNull();
  });
});
