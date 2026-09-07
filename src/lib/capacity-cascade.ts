type TableRef = { sectionId: string | null; seats: number };

// Sum of seats per section (by section id) and overall - pure, no I/O.
// Drives the live capacity preview in the edit form: whenever sections or
// an active layout exist, the displayed total/per-section capacity is
// always computed fresh from sections/tables via this function, never read
// from the restaurants.capacity/sections.capacity columns - those are only
// written to (and only ever meaningful) in "no sections, no active
// layout" mode, so a manually-typed number survives being overwritten
// while sections/layouts are driving the display, ready to fall back to
// once they're removed.
export function computeCapacitySums(tables: TableRef[]) {
  const bySection = new Map<string, number>();
  for (const t of tables) {
    if (t.sectionId) bySection.set(t.sectionId, (bySection.get(t.sectionId) ?? 0) + t.seats);
  }
  const total = tables.reduce((sum, t) => sum + t.seats, 0);
  return { bySection, total };
}
