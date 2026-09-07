"use client";

import { useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { sectionColor } from "@/lib/section-colors";

const GRID_UNIT = 24; // px per grid unit
const GRID_COLS = 60;
const GRID_ROWS = 40;
const VIEWPORT_HEIGHT = 506; // px, the visible window - 25% shorter than before; the scrollable canvas itself (GRID_ROWS) is unchanged
const DEFAULT_SIZE = 2;
const MIN_SIZE = 1;

export type SectionOption = { key: string; name: string; colorIndex: number };
// A table not yet saved has id: null. sectionKey references a
// SectionOption's key (which is the section's real id once it has one, or
// a local draft key for a section that hasn't been saved yet either -
// resolved to a real id only when the whole form is finally submitted).
export type DraftTable = {
  key: string;
  id: string | null;
  name: string;
  seats: string;
  sectionKey: string | null;
  x: number;
  y: number;
  width: number;
  height: number;
};
type Rect = { x: number; y: number; width: number; height: number };

function clamp(value: number, min: number, max: number) {
  return Math.min(Math.max(value, min), max);
}

function rectsOverlap(a: Rect, b: Rect) {
  return a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y;
}

function collidesWithAny(candidate: Rect, others: Rect[]) {
  return others.some((o) => rectsOverlap(candidate, o));
}

// Scans for the first free grid cell (top-left, row-major) that fits a
// width x height table without overlapping any existing one.
function findFreePosition(width: number, height: number, others: Rect[]): { x: number; y: number } {
  for (let y = 0; y <= GRID_ROWS - height; y++) {
    for (let x = 0; x <= GRID_COLS - width; x++) {
      if (!collidesWithAny({ x, y, width, height }, others)) return { x, y };
    }
  }
  return { x: 0, y: 0 };
}

type Interaction =
  | {
      type: "move";
      keys: string[];
      startPointerX: number;
      startPointerY: number;
      startPositions: Record<string, { x: number; y: number }>;
    }
  | { type: "resize"; key: string; startPointerX: number; startPointerY: number; startWidth: number; startHeight: number }
  | { type: "marquee"; startX: number; startY: number; currentX: number; currentY: number }
  | null;

export function TableLayoutEditor({
  value,
  onChange,
  sections,
}: {
  value: DraftTable[];
  onChange: (next: DraftTable[]) => void;
  sections: SectionOption[];
}) {
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [interaction, setInteraction] = useState<Interaction>(null);
  const canvasRef = useRef<HTMLDivElement | null>(null);

  const hasSections = sections.length > 0;
  const sectionByKey = new Map(sections.map((s) => [s.key, s]));
  const selectedTables = value.filter((t) => selected.has(t.key));

  function addTable() {
    const previous = value[value.length - 1];
    const width = previous?.width ?? DEFAULT_SIZE;
    const height = previous?.height ?? DEFAULT_SIZE;
    const position = findFreePosition(width, height, value);
    const newTable: DraftTable = {
      key: crypto.randomUUID(),
      id: null,
      name: `Sto ${value.length + 1}`,
      seats: previous?.seats ?? "2",
      sectionKey: previous?.sectionKey ?? null,
      x: position.x,
      y: position.y,
      width,
      height,
    };
    onChange([...value, newTable]);
    setSelected(new Set([newTable.key]));
  }

  function updateTable(key: string, patch: Partial<DraftTable>) {
    onChange(value.map((t) => (t.key === key ? { ...t, ...patch } : t)));
  }

  function removeSelected() {
    onChange(value.filter((t) => !selected.has(t.key)));
    setSelected(new Set());
  }

  function bulkAssignSection(sectionKey: string) {
    onChange(value.map((t) => (selected.has(t.key) ? { ...t, sectionKey } : t)));
  }

  function gridPointFromEvent(event: { clientX: number; clientY: number }) {
    const el = canvasRef.current;
    if (!el) return { x: 0, y: 0 };
    const rect = el.getBoundingClientRect();
    return { x: (event.clientX - rect.left) / GRID_UNIT, y: (event.clientY - rect.top) / GRID_UNIT };
  }

  function handleTablePointerDown(event: ReactPointerEvent<HTMLDivElement>, table: DraftTable) {
    event.stopPropagation();
    const additive = event.shiftKey || event.ctrlKey || event.metaKey;
    let nextSelected: Set<string>;
    if (additive) {
      nextSelected = new Set(selected);
      if (nextSelected.has(table.key)) nextSelected.delete(table.key);
      else nextSelected.add(table.key);
    } else if (selected.has(table.key)) {
      nextSelected = selected; // dragging an already-selected table moves the whole group
    } else {
      nextSelected = new Set([table.key]);
    }
    setSelected(nextSelected);
    if (!nextSelected.has(table.key)) return;

    event.currentTarget.setPointerCapture(event.pointerId);
    const startPositions: Record<string, { x: number; y: number }> = {};
    for (const t of value) {
      if (nextSelected.has(t.key)) startPositions[t.key] = { x: t.x, y: t.y };
    }
    setInteraction({
      type: "move",
      keys: [...nextSelected],
      startPointerX: event.clientX,
      startPointerY: event.clientY,
      startPositions,
    });
  }

  function handleResizeHandlePointerDown(event: ReactPointerEvent<HTMLDivElement>, table: DraftTable) {
    event.stopPropagation();
    event.currentTarget.setPointerCapture(event.pointerId);
    setInteraction({
      type: "resize",
      key: table.key,
      startPointerX: event.clientX,
      startPointerY: event.clientY,
      startWidth: table.width,
      startHeight: table.height,
    });
  }

  function handleCanvasPointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    if (event.target !== event.currentTarget) return;
    const point = gridPointFromEvent(event);
    setSelected(new Set());
    event.currentTarget.setPointerCapture(event.pointerId);
    setInteraction({ type: "marquee", startX: point.x, startY: point.y, currentX: point.x, currentY: point.y });
  }

  function handlePointerMove(event: ReactPointerEvent<HTMLDivElement>) {
    if (!interaction) return;

    if (interaction.type === "move") {
      const deltaX = Math.round((event.clientX - interaction.startPointerX) / GRID_UNIT);
      const deltaY = Math.round((event.clientY - interaction.startPointerY) / GRID_UNIT);
      const movingKeys = new Set(interaction.keys);
      const others = value.filter((t) => !movingKeys.has(t.key));
      const candidates = value.map((t) => {
        const start = interaction.startPositions[t.key];
        if (!start) return t;
        return {
          ...t,
          x: clamp(start.x + deltaX, 0, GRID_COLS - t.width),
          y: clamp(start.y + deltaY, 0, GRID_ROWS - t.height),
        };
      });
      const moved = candidates.filter((t) => movingKeys.has(t.key));
      if (!moved.some((c) => collidesWithAny(c, others))) {
        onChange(candidates);
      }
      return;
    }

    if (interaction.type === "resize") {
      const deltaX = Math.round((event.clientX - interaction.startPointerX) / GRID_UNIT);
      const deltaY = Math.round((event.clientY - interaction.startPointerY) / GRID_UNIT);
      const target = value.find((t) => t.key === interaction.key);
      if (!target) return;
      const width = clamp(interaction.startWidth + deltaX, MIN_SIZE, GRID_COLS - target.x);
      const height = clamp(interaction.startHeight + deltaY, MIN_SIZE, GRID_ROWS - target.y);
      const candidate = { x: target.x, y: target.y, width, height };
      const others = value.filter((t) => t.key !== interaction.key);
      if (!collidesWithAny(candidate, others)) {
        onChange(value.map((t) => (t.key === interaction.key ? { ...t, width, height } : t)));
      }
      return;
    }

    // marquee
    const point = gridPointFromEvent(event);
    const next = { ...interaction, currentX: point.x, currentY: point.y };
    setInteraction(next);
    applyMarqueeSelection(next);
  }

  function applyMarqueeSelection(rect: { startX: number; startY: number; currentX: number; currentY: number }) {
    const left = Math.min(rect.startX, rect.currentX);
    const right = Math.max(rect.startX, rect.currentX);
    const top = Math.min(rect.startY, rect.currentY);
    const bottom = Math.max(rect.startY, rect.currentY);
    setSelected(
      new Set(
        value.filter((t) => t.x < right && t.x + t.width > left && t.y < bottom && t.y + t.height > top).map((t) => t.key),
      ),
    );
  }

  function handlePointerUp(event: ReactPointerEvent<HTMLDivElement>) {
    // A drag with no (or very few) intermediate pointermove events would
    // otherwise leave the marquee selection at whatever it was computed as
    // mid-drag (possibly still empty) - finalize against the actual
    // release point so a fast/short drag still selects correctly.
    if (interaction?.type === "marquee") {
      const point = gridPointFromEvent(event);
      applyMarqueeSelection({ ...interaction, currentX: point.x, currentY: point.y });
    }
    setInteraction(null);
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <button
          type="button"
          onClick={addTable}
          className="rounded-md border border-stone-300 px-3 py-1.5 text-sm hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
        >
          Dodaj sto
        </button>
        {sections.length > 0 && (
          <div className="flex flex-wrap items-center gap-2 text-xs text-stone-600 dark:text-stone-400">
            {sections.map((s) => (
              <span key={s.key} className="flex items-center gap-1">
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
      </div>

      {/* Fixed height regardless of content, so the canvas below never
          shifts when a selection appears/disappears. */}
      <div className="flex min-h-[52px] flex-wrap items-center gap-3 rounded-lg border border-stone-200 bg-stone-50 p-3 dark:border-stone-700 dark:bg-stone-900/40">
        {selected.size > 0 &&
          (selected.size === 1 && selectedTables[0] ? (
            <>
              <label className="sr-only" htmlFor="table-name">
                Naziv stola
              </label>
              <input
                id="table-name"
                value={selectedTables[0].name}
                onChange={(event) => updateTable(selectedTables[0].key, { name: event.target.value })}
                placeholder="Naziv"
                className="w-32 rounded-md border border-stone-300 bg-white px-2 py-1 text-sm text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100"
              />
              <label className="sr-only" htmlFor="table-seats">
                Broj mesta
              </label>
              <input
                id="table-seats"
                type="number"
                min={1}
                value={selectedTables[0].seats}
                onChange={(event) => updateTable(selectedTables[0].key, { seats: event.target.value })}
                placeholder="Mesta"
                className="w-20 rounded-md border border-stone-300 bg-white px-2 py-1 text-sm text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100"
              />
            </>
          ) : (
            <span className="text-sm text-stone-600 dark:text-stone-400">Izabrano stolova: {selected.size}</span>
          ))}

        {selected.size > 0 && hasSections && (
          <>
            <label className="sr-only" htmlFor="bulk-section">
              Sekcija
            </label>
            <select
              id="bulk-section"
              value={selected.size === 1 ? (selectedTables[0].sectionKey ?? "") : ""}
              onChange={(event) => bulkAssignSection(event.target.value)}
              className="rounded-md border border-stone-300 bg-white px-2 py-1 text-sm text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100"
            >
              <option value="" disabled>
                Izaberi sekciju
              </option>
              {sections.map((s) => (
                <option key={s.key} value={s.key}>
                  {s.name}
                </option>
              ))}
            </select>
          </>
        )}

        {selected.size > 0 && (
          <button
            type="button"
            onClick={removeSelected}
            className="rounded-md border border-stone-300 px-3 py-1 text-sm text-red-600 hover:bg-stone-100 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
          >
            Obriši izabrano
          </button>
        )}
      </div>

      {/* Fixed-height, full-width viewport with native scroll panning into
          a larger canvas - the grid doesn't need to fit entirely on
          screen. */}
      <div
        className="w-full overflow-auto rounded-lg border border-stone-200 bg-stone-50 dark:border-stone-700 dark:bg-stone-900/40"
        style={{ height: VIEWPORT_HEIGHT }}
      >
        <div
          ref={canvasRef}
          onPointerDown={handleCanvasPointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={handlePointerUp}
          onPointerCancel={handlePointerUp}
          className="relative touch-none select-none"
          style={{ width: GRID_COLS * GRID_UNIT, height: GRID_ROWS * GRID_UNIT }}
        >
          {value.map((t) => {
            const section = t.sectionKey ? sectionByKey.get(t.sectionKey) : undefined;
            const isSelected = selected.has(t.key);
            return (
              <div
                key={t.key}
                onPointerDown={(event) => handleTablePointerDown(event, t)}
                className={`absolute flex cursor-move items-center justify-center rounded-sm border-2 text-center text-[11px] leading-tight text-stone-900 ${
                  isSelected ? "border-accent" : "border-stone-400 dark:border-stone-500"
                }`}
                style={{
                  left: t.x * GRID_UNIT,
                  top: t.y * GRID_UNIT,
                  width: t.width * GRID_UNIT,
                  height: t.height * GRID_UNIT,
                  backgroundColor: section ? sectionColor(section.colorIndex) : undefined,
                }}
              >
                <span className={section ? "" : "text-stone-600 dark:text-stone-300"}>
                  {t.name || "?"}
                  <br />
                  {t.seats || "0"}
                </span>
                {isSelected && selected.size === 1 && (
                  <div
                    onPointerDown={(event) => handleResizeHandlePointerDown(event, t)}
                    className="absolute -right-1 -bottom-1 size-3 cursor-nwse-resize rounded-sm border border-stone-300 bg-accent dark:border-stone-600"
                  />
                )}
              </div>
            );
          })}

          {interaction?.type === "marquee" && (
            <div
              className="pointer-events-none absolute border border-accent bg-accent/10"
              style={{
                left: Math.min(interaction.startX, interaction.currentX) * GRID_UNIT,
                top: Math.min(interaction.startY, interaction.currentY) * GRID_UNIT,
                width: Math.abs(interaction.currentX - interaction.startX) * GRID_UNIT,
                height: Math.abs(interaction.currentY - interaction.startY) * GRID_UNIT,
              }}
            />
          )}
        </div>
      </div>
    </div>
  );
}
