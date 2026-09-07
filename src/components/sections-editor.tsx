"use client";

import { countColorUsage, pickLeastUsedColorIndex, sectionColor } from "@/lib/section-colors";

// A section not yet saved has id: null. key is a stable React/local-list
// identity independent of id, since new rows don't have one yet.
export type DraftSection = { key: string; id: string | null; name: string; capacity: string; colorIndex: number };

export function SectionsEditor({
  value,
  onChange,
  capacityReadOnly,
  liveCapacities,
}: {
  value: DraftSection[];
  onChange: (next: DraftSection[]) => void;
  // Once a layout is current, capacity is derived from its tables (edited
  // right below on the same page) rather than typed here.
  capacityReadOnly: boolean;
  // Live sums (by section key) computed from the current layout's draft
  // tables - always up to date as tables are added/moved/reassigned,
  // without needing anything saved first. Only meaningful when
  // capacityReadOnly is true.
  liveCapacities?: Map<string, number>;
}) {
  function updateSection(key: string, patch: Partial<DraftSection>) {
    onChange(value.map((section) => (section.key === key ? { ...section, ...patch } : section)));
  }

  function removeSection(key: string) {
    onChange(value.filter((section) => section.key !== key));
  }

  function addSection() {
    const colorIndex = pickLeastUsedColorIndex(countColorUsage(value.map((s) => s.colorIndex)));
    onChange([...value, { key: crypto.randomUUID(), id: null, name: "", capacity: "0", colorIndex }]);
  }

  return (
    <div className="space-y-2">
      {value.length === 0 ? (
        <p className="text-sm text-stone-600 dark:text-stone-400">Trenutno nema sekcija.</p>
      ) : (
        <ul className="space-y-2">
          {value.map((section) => (
            <li key={section.key} className="flex items-center gap-2">
              <span
                aria-hidden
                className="size-4 shrink-0 rounded-full border border-stone-300 dark:border-stone-600"
                style={{ backgroundColor: sectionColor(section.colorIndex) }}
              />
              <label htmlFor={`section-name-${section.key}`} className="sr-only">
                Naziv sekcije
              </label>
              <input
                id={`section-name-${section.key}`}
                required
                placeholder="Naziv"
                value={section.name}
                onChange={(event) => updateSection(section.key, { name: event.target.value })}
                className="flex-1 rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
              />
              {capacityReadOnly ? (
                <span
                  title="Kapacitet se izračunava iz rasporeda stolova"
                  className="w-28 shrink-0 rounded-md border border-stone-300 bg-stone-100 px-3 py-2 text-base text-stone-600 dark:border-stone-600 dark:bg-stone-700 dark:text-stone-400"
                >
                  {liveCapacities?.get(section.key) ?? 0}
                </span>
              ) : (
                <>
                  <label htmlFor={`section-capacity-${section.key}`} className="sr-only">
                    Kapacitet sekcije
                  </label>
                  <input
                    id={`section-capacity-${section.key}`}
                    required
                    type="number"
                    min={1}
                    placeholder="Kapacitet"
                    value={section.capacity}
                    onChange={(event) => updateSection(section.key, { capacity: event.target.value })}
                    className="w-28 rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
                  />
                </>
              )}
              <button
                type="button"
                onClick={() => removeSection(section.key)}
                className="shrink-0 rounded-md border border-stone-300 px-3 py-2 text-sm text-red-600 hover:bg-stone-100 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
              >
                Ukloni
              </button>
            </li>
          ))}
        </ul>
      )}
      <button
        type="button"
        onClick={addSection}
        className="rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
      >
        Dodaj sekciju
      </button>
    </div>
  );
}
