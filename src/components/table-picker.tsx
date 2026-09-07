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
  value,
  onChange,
}: {
  tables: PickableTable[];
  layouts: { id: string; name: string }[];
  value: string[];
  onChange: (next: string[]) => void;
}) {
  const [activeLayoutId, setActiveLayoutId] = useState(layouts[0]?.id ?? null);
  const selected = new Set(value);
  const visibleTables = tables.filter((t) => t.layoutId === activeLayoutId);

  function toggle(id: string) {
    const next = new Set(selected);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    onChange([...next]);
  }

  const selectedTables = tables.filter((t) => selected.has(t.id));
  const totalSeats = selectedTables.reduce((sum, t) => sum + t.seats, 0);

  return (
    <div className="space-y-2">
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
            return (
              <button
                key={t.id}
                type="button"
                onClick={() => toggle(t.id)}
                className={`absolute flex cursor-pointer items-center justify-center rounded-sm border-2 text-center text-[11px] leading-tight text-stone-900 focus:outline-hidden focus-visible:ring-2 focus-visible:ring-accent ${
                  isSelected ? "border-accent ring-2 ring-accent" : "border-stone-400 dark:border-stone-500"
                }`}
                style={{
                  left: t.x * GRID_UNIT,
                  top: t.y * GRID_UNIT,
                  width: t.width * GRID_UNIT,
                  height: t.height * GRID_UNIT,
                  backgroundColor: t.sectionColorIndex !== null ? sectionColor(t.sectionColorIndex) : undefined,
                }}
              >
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
        {selected.size === 0
          ? "Nijedan sto nije izabran - restoran će dodeliti sto."
          : `Izabrano stolova: ${selected.size} (mesta: ${totalSeats})`}
      </p>
    </div>
  );
}
