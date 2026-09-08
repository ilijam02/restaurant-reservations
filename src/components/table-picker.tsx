"use client";

import { useState } from "react";
import { sectionColor } from "@/lib/section-colors";

const GRID_UNIT = 24; // px per grid unit, matching table-layout-editor.tsx
const GRID_COLS = 60;
const GRID_ROWS = 40;
const VIEWPORT_HEIGHT = 506;

export type PickableTable = {
  id: string;
  name: string;
  seats: number;
  sectionId: string | null;
  sectionColorIndex: number | null;
  layoutId: string;
  x: number;
  y: number;
  width: number;
  height: number;
};

export function TablePicker({
  tables,
  layouts,
  sections,
  value,
  onChange,
  enabled,
  occupiedTableIds,
}: {
  tables: PickableTable[];
  layouts: { id: string; name: string }[];
  sections: { id: string; name: string; colorIndex: number }[];
  value: string[];
  onChange: (next: string[]) => void;
  // Time/duration must be chosen first - availability (and thus which
  // tables are even pickable) is meaningless without a candidate range.
  enabled: boolean;
  occupiedTableIds: Set<string>;
}) {
  const [activeLayoutId, setActiveLayoutId] = useState(layouts[0]?.id ?? null);
  const selected = new Set(value);
  const visibleTables = tables.filter((t) => t.layoutId === activeLayoutId);

  function toggle(id: string) {
    if (!enabled || occupiedTableIds.has(id)) return;
    const next = new Set(selected);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    onChange([...next]);
  }

  const selectedTables = tables.filter((t) => selected.has(t.id));
  const totalSeats = selectedTables.reduce((sum, t) => sum + t.seats, 0);

  return (
    <div className="space-y-2">
      {sections.length > 0 && (
        <div className="flex flex-wrap items-center gap-2 text-xs text-stone-600 dark:text-stone-400">
          {sections.map((s) => (
            <span key={s.id} className="flex items-center gap-1">
              <span
                aria-hidden
                className="size-3 rounded-full border border-stone-300 dark:border-stone-600"
                style={{ backgroundColor: sectionColor(s.colorIndex) }}
              />
              {s.name}
            </span>
          ))}
        </div>
      )}

      {layouts.length > 1 && (
        <div className="flex flex-wrap gap-2">
          {layouts.map((l) => (
            <button
              key={l.id}
              type="button"
              onClick={() => setActiveLayoutId(l.id)}
              className={`rounded-md border px-3 py-1 text-sm ${
                activeLayoutId === l.id
                  ? "border-accent bg-accent text-accent-foreground"
                  : "border-stone-300 hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
              }`}
            >
              {l.name}
            </button>
          ))}
        </div>
      )}

      <div
        className="w-full overflow-auto rounded-lg border border-stone-200 bg-stone-50 dark:border-stone-700 dark:bg-stone-900/40"
        style={{ height: VIEWPORT_HEIGHT }}
      >
        <div className="relative" style={{ width: GRID_COLS * GRID_UNIT, height: GRID_ROWS * GRID_UNIT }}>
          {visibleTables.map((t) => {
            const isSelected = selected.has(t.id);
            const isOccupied = enabled && occupiedTableIds.has(t.id);
            const borderClass = isSelected
              ? "border-accent ring-2 ring-accent"
              : !enabled
                ? "border-stone-400 dark:border-stone-500"
                : isOccupied
                  ? "border-danger"
                  : "border-success";
            return (
              <button
                key={t.id}
                type="button"
                disabled={!enabled || isOccupied}
                onClick={() => toggle(t.id)}
                aria-label={enabled ? `${t.name}, ${t.seats} mesta, ${isOccupied ? "zauzeto" : "slobodno"}` : undefined}
                className={`absolute flex items-center justify-center rounded-sm border-2 text-center text-[11px] leading-tight text-stone-900 focus:outline-hidden focus-visible:ring-2 focus-visible:ring-accent ${borderClass} ${
                  !enabled ? "cursor-not-allowed opacity-60" : isOccupied ? "cursor-not-allowed opacity-70" : "cursor-pointer"
                }`}
                style={{
                  left: t.x * GRID_UNIT,
                  top: t.y * GRID_UNIT,
                  width: t.width * GRID_UNIT,
                  height: t.height * GRID_UNIT,
                  backgroundColor: t.sectionColorIndex !== null ? sectionColor(t.sectionColorIndex) : undefined,
                }}
              >
                {/* Status is never color-only (see CLAUDE.md) - the
                    free/occupied border color is paired with a shape icon
                    too, so it still reads for color-blind users. */}
                {enabled && !isSelected && (
                  <span
                    aria-hidden
                    className={`absolute -top-1.5 -right-1.5 flex size-3 items-center justify-center rounded-full border border-white text-[8px] leading-none text-white dark:border-stone-900 ${
                      isOccupied ? "bg-danger" : "bg-success"
                    }`}
                  >
                    {isOccupied ? "✕" : "✓"}
                  </span>
                )}
                <span className={t.sectionColorIndex !== null ? "" : "text-stone-600 dark:text-stone-300"}>
                  {t.name}
                  <br />
                  {t.seats}
                </span>
              </button>
            );
          })}
        </div>
      </div>

      <p className="text-xs text-stone-600 dark:text-stone-400">
        {!enabled
          ? "Izaberite datum, vreme i trajanje da biste videli dostupne stolove."
          : selected.size === 0
            ? "Nijedan sto nije izabran - restoran će dodeliti sto."
            : `Izabrano stolova: ${selected.size} (mesta: ${totalSeats})`}
      </p>
    </div>
  );
}
