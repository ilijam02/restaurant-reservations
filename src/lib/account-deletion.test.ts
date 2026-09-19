import { describe, expect, it } from "vitest";
import { deletionBlockedMessage, type AccountDeletionPlan } from "./account-deletion";

const plan = (overrides: Partial<AccountDeletionPlan> = {}): AccountDeletionPlan => ({
  role: "customer",
  active_reservations: 0,
  history_reservations: 0,
  blocking_restaurants: [],
  restaurants_to_delete: [],
  restaurants_to_archive: 0,
  ...overrides,
});

describe("deletionBlockedMessage", () => {
  it("is null when nothing is active", () => {
    expect(deletionBlockedMessage(plan())).toBeNull();
    expect(deletionBlockedMessage(plan({ history_reservations: 3, restaurants_to_archive: 1 }))).toBeNull();
  });

  it("blocks on the customer's own active bookings", () => {
    expect(deletionBlockedMessage(plan({ active_reservations: 2 }))).toBe(
      "Imate aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.",
    );
  });

  it("blocks on an owned restaurant with an active booking, naming the first one", () => {
    const message = deletionBlockedMessage(
      plan({
        role: "owner",
        blocking_restaurants: [
          { id: "a", name: "Alfa", active_reservations: 1 },
          { id: "b", name: "Beta", active_reservations: 4 },
        ],
      }),
    );
    expect(message).toBe("Restoran „Alfa” ima aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.");
  });

  it("reports the customer's own bookings before an owned restaurant's", () => {
    const message = deletionBlockedMessage(
      plan({ active_reservations: 1, blocking_restaurants: [{ id: "a", name: "Alfa", active_reservations: 1 }] }),
    );
    expect(message).toMatch(/^Imate aktivne rezervacije/);
  });
});
