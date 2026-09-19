import { describe, expect, it } from "vitest";
import { pluralSr } from "./plural";

const form = (n: number) => pluralSr(n, "stavka", "stavke", "stavki");

describe("pluralSr", () => {
  it("uses the singular for 1, 21, 101 but not 11", () => {
    expect([1, 21, 101].map(form)).toEqual(["stavka", "stavka", "stavka"]);
    expect(form(11)).toBe("stavki");
  });

  it("uses the few form for 2-4, 22-24 but not 12-14", () => {
    expect([2, 3, 4, 22, 24, 102].map(form)).toEqual(Array(6).fill("stavke"));
    expect([12, 13, 14].map(form)).toEqual(Array(3).fill("stavki"));
  });

  it("uses the many form for 0, 5-20 and 25-30", () => {
    expect([0, 5, 10, 15, 20, 25, 30].map(form)).toEqual(Array(7).fill("stavki"));
  });
});
