"use client";

import { useRef, useState, type PointerEvent as ReactPointerEvent } from "react";

export type HourBlock = { id: string; dayOfWeek: number; start: number; end: number };

// day_of_week follows Postgres's extract(dow from ...) convention
// (0 = Sunday .. 6 = Saturday); displayed Monday-first for the owner.
const DISPLAY_DAYS: { dayOfWeek: number; label: string }[] = [
  { dayOfWeek: 1, label: "Pon" },
  { dayOfWeek: 2, label: "Uto" },
  { dayOfWeek: 3, label: "Sre" },
  { dayOfWeek: 4, label: "Čet" },
  { dayOfWeek: 5, label: "Pet" },
  { dayOfWeek: 6, label: "Sub" },
  { dayOfWeek: 0, label: "Ned" },
];

const ROW_HEIGHT = 40; // px, height of each day's track
const SNAP_MIN = 30;
const HOUR_MARKS = Array.from({ length: 13 }, (_, i) => i * 2); // 0,2,4,...,24

function formatMinutes(min: number) {
  const h = Math.floor(min / 60) % 24;
  const m = min % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

function snap(min: number) {
  return Math.round(min / SNAP_MIN) * SNAP_MIN;
}

function pct(min: number) {
  return `${(min / 1440) * 100}%`;
}

export function RestaurantHoursCalendar({
  value,
  onChange,
}: {
  value: HourBlock[];
  onChange: (blocks: HourBlock[]) => void;
}) {
  const [drag, setDrag] = useState<{ dayOfWeek: number; anchor: number; current: number } | null>(null);
  const rowRefs = useRef<Record<number, HTMLDivElement | null>>({});

  function blocksForDay(dayOfWeek: number) {
    return value.filter((b) => b.dayOfWeek === dayOfWeek).sort((a, b) => a.start - b.start);
  }

  // Finds how far a drag starting at `anchor` may extend before it would
  // overlap an existing block in the same day; returns null if `anchor`
  // itself falls inside one (dragging isn't allowed to start there).
  function clampBounds(dayOfWeek: number, anchor: number) {
    let lower = 0;
    let upper = 1440;
    for (const b of blocksForDay(dayOfWeek)) {
      if (anchor > b.start && anchor < b.end) return null;
      if (b.end <= anchor && b.end > lower) lower = b.end;
      if (b.start >= anchor && b.start < upper) upper = b.start;
    }
    return { lower, upper };
  }

  function minuteFromClientX(dayOfWeek: number, clientX: number) {
    const el = rowRefs.current[dayOfWeek];
    if (!el) return 0;
    const rect = el.getBoundingClientRect();
    const raw = ((clientX - rect.left) / rect.width) * 1440;
    return Math.min(1440, Math.max(0, snap(raw)));
  }

  function handlePointerDown(dayOfWeek: number, event: ReactPointerEvent<HTMLDivElement>) {
    const minute = minuteFromClientX(dayOfWeek, event.clientX);
    if (!clampBounds(dayOfWeek, minute)) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    setDrag({ dayOfWeek, anchor: minute, current: minute });
  }

  function handlePointerMove(event: ReactPointerEvent<HTMLDivElement>) {
    if (!drag) return;
    const bounds = clampBounds(drag.dayOfWeek, drag.anchor);
    if (!bounds) return;
    const raw = minuteFromClientX(drag.dayOfWeek, event.clientX);
    const clamped = Math.min(bounds.upper, Math.max(bounds.lower, raw));
    setDrag({ ...drag, current: clamped });
  }

  function handlePointerUp() {
    if (!drag) return;
    const start = Math.min(drag.anchor, drag.current);
    const end = Math.max(drag.anchor, drag.current);
    if (end - start >= SNAP_MIN) {
      onChange([...value, { id: crypto.randomUUID(), dayOfWeek: drag.dayOfWeek, start, end }]);
    }
    setDrag(null);
  }

  function removeBlock(id: string) {
    onChange(value.filter((b) => b.id !== id));
  }

  function applyMondayToAll() {
    const monday = value.filter((b) => b.dayOfWeek === 1);
    const rest = DISPLAY_DAYS.filter((d) => d.dayOfWeek !== 1).flatMap((d) =>
      monday.map((b) => ({ id: crypto.randomUUID(), dayOfWeek: d.dayOfWeek, start: b.start, end: b.end })),
    );
    onChange([...monday, ...rest]);
  }

  return (
    <div>
      <div className="mb-2 flex items-center justify-between gap-2">
        <p className="text-xs text-stone-600 dark:text-stone-400">
          Prevucite preko dana da označite kada je restoran otvoren.
        </p>
        <button
          type="button"
          onClick={applyMondayToAll}
          className="shrink-0 text-sm font-medium text-orange-700 hover:underline dark:text-accent"
        >
          Primeni na sve
        </button>
      </div>

      <div>
        <div className="flex">
          <div className="w-9 shrink-0" />
          <div className="relative h-4 flex-1">
            {HOUR_MARKS.map((h) => (
              <div
                key={h}
                className="absolute -translate-x-1/2 text-[10px] text-stone-500 dark:text-stone-400"
                style={{ left: pct(h * 60) }}
              >
                {String(h % 24).padStart(2, "0")}
              </div>
            ))}
          </div>
        </div>

        {DISPLAY_DAYS.map((day) => {
          const dayBlocks = blocksForDay(day.dayOfWeek);
          const isDraggingThisDay = drag?.dayOfWeek === day.dayOfWeek;
          const previewStart = isDraggingThisDay ? Math.min(drag.anchor, drag.current) : 0;
          const previewEnd = isDraggingThisDay ? Math.max(drag.anchor, drag.current) : 0;

          return (
            <div key={day.dayOfWeek} className="flex items-center">
              <div className="w-9 shrink-0 text-xs font-medium text-stone-700 dark:text-stone-300">
                {day.label}
              </div>
              <div
                ref={(el) => {
                  rowRefs.current[day.dayOfWeek] = el;
                }}
                onPointerDown={(event) => handlePointerDown(day.dayOfWeek, event)}
                onPointerMove={handlePointerMove}
                onPointerUp={handlePointerUp}
                onPointerCancel={() => setDrag(null)}
                className="relative flex-1 touch-none border-t border-stone-200 bg-stone-50 select-none dark:border-stone-700 dark:bg-stone-900/40"
                style={{ height: ROW_HEIGHT }}
              >
                {HOUR_MARKS.map((h) => (
                  <div
                    key={h}
                    className="pointer-events-none absolute inset-y-0 border-l border-stone-200 dark:border-stone-700/60"
                    style={{ left: pct(h * 60) }}
                  />
                ))}

                {dayBlocks.map((b) => (
                  <div
                    key={b.id}
                    title={`${formatMinutes(b.start)}–${formatMinutes(b.end)}`}
                    className="absolute inset-y-0.5 rounded-sm bg-accent/80 text-accent-foreground"
                    style={{ left: pct(b.start), width: `max(3px, ${pct(b.end - b.start)})` }}
                  >
                    <span className="block overflow-hidden px-1 pr-4 text-[10px] leading-tight whitespace-nowrap">
                      {formatMinutes(b.start)}–{formatMinutes(b.end)}
                    </span>
                    <button
                      type="button"
                      onPointerDown={(event) => event.stopPropagation()}
                      onClick={(event) => {
                        event.stopPropagation();
                        removeBlock(b.id);
                      }}
                      aria-label={`Ukloni ${day.label} ${formatMinutes(b.start)}–${formatMinutes(b.end)}`}
                      className="absolute top-0 right-0 flex h-full w-4 items-center justify-center leading-none text-accent-foreground/80 hover:text-accent-foreground"
                    >
                      ×
                    </button>
                  </div>
                ))}

                {isDraggingThisDay && previewEnd > previewStart && (
                  <div
                    className="pointer-events-none absolute inset-y-0.5 rounded-sm bg-accent/40"
                    style={{ left: pct(previewStart), width: pct(previewEnd - previewStart) }}
                  />
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
