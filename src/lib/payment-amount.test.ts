import { describe, expect, it } from "vitest";
import {
  DEFAULT_RSD_PER_EUR,
  chargeAmountMinor,
  chargeConfigFromEnv,
  orderTotalMinorRsd,
} from "../../supabase/functions/_shared/payment-amount";

describe("orderTotalMinorRsd", () => {
  it("sums unit_price * quantity in para without float drift", () => {
    // 0.1 + 0.2 style traps: 3 x 10.10 and 1 x 0.20.
    expect(orderTotalMinorRsd([{ unit_price: 10.1, quantity: 3 }, { unit_price: 0.2, quantity: 1 }])).toBe(3050);
  });

  it("accepts numeric strings (PostgREST can return numerics as strings)", () => {
    expect(orderTotalMinorRsd([{ unit_price: "450.00", quantity: 2 }])).toBe(90000);
  });

  it("is zero for no items", () => {
    expect(orderTotalMinorRsd([])).toBe(0);
  });
});

describe("chargeConfigFromEnv", () => {
  it("defaults to EUR at the fixed rate", () => {
    expect(chargeConfigFromEnv(() => undefined)).toEqual({ currency: "eur", rsdPerEur: DEFAULT_RSD_PER_EUR });
  });

  it("reads currency and rate, ignoring an unusable rate", () => {
    expect(chargeConfigFromEnv((n) => ({ PAYMENT_CURRENCY: "RSD", RSD_PER_EUR: "120" })[n])).toEqual({
      currency: "rsd",
      rsdPerEur: 120,
    });
    expect(chargeConfigFromEnv((n) => ({ RSD_PER_EUR: "abc" })[n]).rsdPerEur).toBe(DEFAULT_RSD_PER_EUR);
    expect(chargeConfigFromEnv((n) => ({ RSD_PER_EUR: "-5" })[n]).rsdPerEur).toBe(DEFAULT_RSD_PER_EUR);
  });

  it("treats any currency other than rsd as eur", () => {
    expect(chargeConfigFromEnv((n) => ({ PAYMENT_CURRENCY: "usd" })[n]).currency).toBe("eur");
  });
});

describe("chargeAmountMinor", () => {
  it("converts RSD para to euro cents at the rate", () => {
    // 11700.00 RSD at 117 = 100.00 EUR = 10000 cents.
    expect(chargeAmountMinor(1_170_000, { currency: "eur", rsdPerEur: 117 })).toBe(10000);
  });

  it("rounds to the nearest cent", () => {
    // 1000.00 RSD / 117 = 8.5470... EUR = 855 cents.
    expect(chargeAmountMinor(100_000, { currency: "eur", rsdPerEur: 117 })).toBe(855);
  });

  it("charges RSD para directly when configured for RSD", () => {
    expect(chargeAmountMinor(123_456, { currency: "rsd", rsdPerEur: 117 })).toBe(123_456);
  });

  it("rejects an amount under Stripe's minimum", () => {
    expect(() => chargeAmountMinor(1000, { currency: "eur", rsdPerEur: 117 })).toThrow("premali");
    expect(() => chargeAmountMinor(0, { currency: "rsd", rsdPerEur: 117 })).toThrow("premali");
  });
});
