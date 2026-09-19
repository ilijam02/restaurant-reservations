import { describe, expect, it } from "vitest";
import { DELETED_CUSTOMER_NAME, resolveCustomerName } from "./owner-reservations";

describe("resolveCustomerName", () => {
  const names = new Map([["c1", "Ana Anić"]]);

  it("returns the profile name of a known customer", () => {
    expect(resolveCustomerName("c1", names)).toBe("Ana Anić");
  });

  it("marks a booking whose customer deleted their account", () => {
    expect(resolveCustomerName(null, names)).toBe(DELETED_CUSTOMER_NAME);
    expect(DELETED_CUSTOMER_NAME).toBe("Obrisan korisnik");
  });

  it("returns null for a customer with no profile row, so the list falls back to Nepoznat korisnik", () => {
    expect(resolveCustomerName("c2", names)).toBeNull();
  });
});
