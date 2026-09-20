// Pure money helpers for the payment Edge Functions - no Deno or Stripe APIs,
// so vitest can import this file directly (src/lib/payment-amount.test.ts).
//
// Prices in the database are RSD, numeric(10,2). Stripe test mode is charged
// in EUR at a fixed rate by default, because settling RSD isn't something the
// Stripe test setup here has been verified for (Stripe isn't available in
// Serbia). Set PAYMENT_CURRENCY=rsd to charge RSD directly if a test call
// proves it works; RSD_PER_EUR only matters for the EUR default.

export type ChargeConfig = { currency: "eur" | "rsd"; rsdPerEur: number };

export const DEFAULT_RSD_PER_EUR = 117;

// Stripe's minimum charge is about 0.50 in the charge currency.
const MIN_MINOR_UNITS = 50;

export function chargeConfigFromEnv(get: (name: string) => string | undefined): ChargeConfig {
  const currency = (get("PAYMENT_CURRENCY") ?? "eur").toLowerCase() === "rsd" ? "rsd" : "eur";
  const rate = Number(get("RSD_PER_EUR"));
  return { currency, rsdPerEur: Number.isFinite(rate) && rate > 0 ? rate : DEFAULT_RSD_PER_EUR };
}

// Sum of unit_price * quantity in whole para (1/100 RSD), so no float drift
// from adding numeric(10,2) values as JS numbers.
export function orderTotalMinorRsd(items: { unit_price: number | string; quantity: number }[]): number {
  return items.reduce((sum, item) => sum + Math.round(Number(item.unit_price) * 100) * item.quantity, 0);
}

// The Stripe amount in the charge currency's minor units.
export function chargeAmountMinor(totalMinorRsd: number, config: ChargeConfig): number {
  const amount = config.currency === "rsd" ? totalMinorRsd : Math.round(totalMinorRsd / config.rsdPerEur);
  if (!Number.isInteger(amount) || amount < MIN_MINOR_UNITS) {
    throw new Error("Iznos porudžbine je premali za plaćanje karticom.");
  }
  return amount;
}
