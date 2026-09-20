import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { consumeSignalsChanged, markSignalsChanged } from "./recommendation-signals";

function fakeStorage() {
  const data = new Map<string, string>();
  return {
    getItem: (key: string) => data.get(key) ?? null,
    setItem: (key: string, value: string) => void data.set(key, value),
    removeItem: (key: string) => void data.delete(key),
  };
}

describe("recommendation signal flag", () => {
  beforeEach(() => {
    vi.stubGlobal("window", { sessionStorage: fakeStorage() });
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("is off until a signal is recorded", () => {
    expect(consumeSignalsChanged()).toBe(false);
  });

  it("is on once after a signal is recorded, then off again", () => {
    markSignalsChanged();
    expect(consumeSignalsChanged()).toBe(true);
    expect(consumeSignalsChanged()).toBe(false);
  });

  it("does not throw when storage is unavailable", () => {
    vi.stubGlobal("window", {
      get sessionStorage(): never {
        throw new Error("blocked");
      },
    });
    expect(() => markSignalsChanged()).not.toThrow();
    expect(consumeSignalsChanged()).toBe(false);
  });
});
