"use client";

import { useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { sectionColor } from "@/lib/section-colors";
import { writeDerivedCapacity } from "@/lib/capacity-cascade";

const GRID_UNIT = 24; // px per grid unit
const GRID_COLS = 60;
const GRID_ROWS = 40;
const VIEWPORT_HEIGHT = 675; // px, the visible/pannable window into the canvas - width matches its container instead of a fixed number
const DEFAULT_SIZE = 2;
const MIN_SIZE = 1;

const SAVE_ERROR = "Čuvanje rasporeda nije uspelo. Pokušajte ponovo.";
const MISSING_SECTION_ERROR = "Svi stolovi moraju imati sekciju - izaberite stolove i dodelite im sekciju.";

type SectionOption = { id: string; name: string; colorIndex: number };
type TableRow = {
  id: string;
  name: string;
  seats: number;
  section_id: string | null;
  x: number;
  y: number;
  width: number;
  height: number;
};
type DraftTable = {
  key: string;
  id: string | null;
  name: string;
  seats: string;
  sectionId: string | null;
  x: number;
  y: number;
  width: number;
  height: number;
};
type Rect = { x: number; y: number; width: number; height: number };

function initialDraftTables(tables: TableRow[]): DraftTable[] {
  return tables.map((t) => ({
    key: crypto.randomUUID(),
    id: t.id,
    name: t.name,
    seats: t.seats.toString(),
    sectionId: t.section_id,
    x: t.x,
    y: t.y,
    width: t.width,
    height: t.height,
  }));
}

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
  restaurantId,
  layoutId,
  isCurrentLayout,
  sections,
  tables,
}: {
  restaurantId: string;
  layoutId: string;
  isCurrentLayout: boolean;
  sections: SectionOption[];
  tables: TableRow[];
}) {
  const router = useRouter();
  const [draftTables, setDraftTables] = useState<DraftTable[]>(() => initialDraftTables(tables));
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [interaction, setInteraction] = useState<Interaction>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const canvasRef = useRef<HTMLDivElement | null>(null);

  const hasSections = sections.length > 0;
  const sectionById = new Map(sections.map((s) => [s.id, s]));
  const selectedTables = draftTables.filter((t) => selected.has(t.key));

  function addTable() {
    const previous = draftTables[draftTables.length - 1];
    const width = previous?.width ?? DEFAULT_SIZE;
    const height = previous?.height ?? DEFAULT_SIZE;
    const position = findFreePosition(width, height, draftTables);
    const newTable: DraftTable = {
      key: crypto.randomUUID(),
      id: null,
      name: `Sto ${draftTables.length + 1}`,
      seats: previous?.seats ?? "2",
      sectionId: previous?.sectionId ?? null,
      x: position.x,
      y: position.y,
      width,
      height,
    };
    setDraftTables((prev) => [...prev, newTable]);
    setSelected(new Set([newTable.key]));
  }

  function updateTable(key: string, patch: Partial<DraftTable>) {
    setDraftTables((prev) => prev.map((t) => (t.key === key ? { ...t, ...patch } : t)));
  }

  function removeSelected() {
    setDraftTables((prev) => prev.filter((t) => !selected.has(t.key)));
    setSelected(new Set());
  }

  function bulkAssignSection(sectionId: string) {
    setDraftTables((prev) => prev.map((t) => (selected.has(t.key) ? { ...t, sectionId } : t)));
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
    for (const t of draftTables) {
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
      const others = draftTables.filter((t) => !movingKeys.has(t.key));
      const candidates = draftTables.map((t) => {
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
        setDraftTables(candidates);
      }
      return;
    }

    if (interaction.type === "resize") {
      const deltaX = Math.round((event.clientX - interaction.startPointerX) / GRID_UNIT);
      const deltaY = Math.round((event.clientY - interaction.startPointerY) / GRID_UNIT);
      const target = draftTables.find((t) => t.key === interaction.key);
      if (!target) return;
      const width = clamp(interaction.startWidth + deltaX, MIN_SIZE, GRID_COLS - target.x);
      const height = clamp(interaction.startHeight + deltaY, MIN_SIZE, GRID_ROWS - target.y);
      const candidate = { x: target.x, y: target.y, width, height };
      const others = draftTables.filter((t) => t.key !== interaction.key);
      if (!collidesWithAny(candidate, others)) {
        setDraftTables((prev) => prev.map((t) => (t.key === interaction.key ? { ...t, width, height } : t)));
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
        draftTables
          .filter((t) => t.x < right && t.x + t.width > left && t.y < bottom && t.y + t.height > top)
          .map((t) => t.key),
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

  async function handleSave() {
    setError(null);

    if (isCurrentLayout && hasSections && draftTables.some((t) => t.sectionId === null)) {
      setError(MISSING_SECTION_ERROR);
      return;
    }

    setLoading(true);
    const supabase = createClient();

    const removedIds = tables.filter((original) => !draftTables.some((d) => d.id === original.id)).map((t) => t.id);
    const { error: deleteError } = removedIds.length
      ? await supabase.from("tables").delete().in("id", removedIds)
      : { error: null };

    if (deleteError) {
      setLoading(false);
      setError(SAVE_ERROR);
      return;
    }

    const originalById = new Map(tables.map((t) => [t.id, t]));
    const toInsert = draftTables.filter((t) => t.id === null);
    const toUpdate = draftTables.filter((t): t is DraftTable & { id: string } => {
      if (t.id === null) return false;
      const original = originalById.get(t.id);
      if (!original) return true;
      return (
        original.name !== t.name ||
        original.seats !== Number(t.seats) ||
        original.section_id !== t.sectionId ||
        original.x !== t.x ||
        original.y !== t.y ||
        original.width !== t.width ||
        original.height !== t.height
      );
    });

    const { error: insertError } = toInsert.length
      ? await supabase.from("tables").insert(
          toInsert.map((t) => ({
            restaurant_id: restaurantId,
            layout_id: layoutId,
            section_id: t.sectionId,
            name: t.name,
            seats: Number(t.seats),
            x: t.x,
            y: t.y,
            width: t.width,
            height: t.height,
          })),
        )
      : { error: null };

    const updateResults = insertError
      ? []
      : await Promise.all(
          toUpdate.map((t) =>
            supabase
              .from("tables")
              .update({
                name: t.name,
                seats: Number(t.seats),
                section_id: t.sectionId,
                x: t.x,
                y: t.y,
                width: t.width,
                height: t.height,
              })
              .eq("id", t.id),
          ),
        );
    const tablesError = insertError ?? updateResults.map((r) => r.error).find((e) => e !== null) ?? null;

    if (tablesError) {
      setLoading(false);
      setError(SAVE_ERROR);
      return;
    }

    // Capacity only ever derives from the restaurant's *current* layout -
    // editing a different, non-current one doesn't touch it.
    if (isCurrentLayout) {
      // draftTables already reflects exactly what was just persisted
      // (removed rows filtered out, updated/new rows holding their final
      // values). An empty result means this layout was just emptied out
      // entirely - capacity then unfreezes, seeded from what it was
      // derived as right before this save (the *original* tables, since
      // the draft is now empty).
      const source =
        draftTables.length > 0
          ? draftTables.map((t) => ({ sectionId: t.sectionId, seats: Number(t.seats) }))
          : tables.map((t) => ({ sectionId: t.section_id, seats: t.seats }));

      const { error: capacityError } = await writeDerivedCapacity(supabase, restaurantId, sections, source);

      if (capacityError) {
        setLoading(false);
        setError(SAVE_ERROR);
        return;
      }
    }

    setLoading(false);
    router.push(`/owner/restaurants/${restaurantId}/edit`);
  }

  return (
    <div className="w-full max-w-4xl space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
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
        </div>
        <button
          type="button"
          onClick={handleSave}
          disabled={loading}
          className="rounded-md bg-accent px-4 py-1.5 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-900"
        >
          {loading ? "Čuvanje..." : "Sačuvaj raspored"}
        </button>
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
              value={selected.size === 1 ? (selectedTables[0].sectionId ?? "") : ""}
              onChange={(event) => bulkAssignSection(event.target.value)}
              className="rounded-md border border-stone-300 bg-white px-2 py-1 text-sm text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100"
            >
              <option value="" disabled>
                Izaberi sekciju
              </option>
              {sections.map((s) => (
                <option key={s.id} value={s.id}>
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
          {draftTables.map((t) => {
            const section = t.sectionId ? sectionById.get(t.sectionId) : undefined;
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

      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}
    </div>
  );
}
