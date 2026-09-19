"use client";

import { useEffect, useRef, useState } from "react";

// Sub-pixel rounding can make scroll and client widths differ by a pixel
// without anything actually being cut off.
const OVERFLOW_TOLERANCE_PX = 1;

// A name that stays on one line (ellipsized) and gets a chevron to show the
// whole thing only when it doesn't fit. Long unbroken strings wrap at any
// character once expanded, so nothing is ever lost.
export function ExpandableName({ name, className = "" }: { name: string; className?: string }) {
  const nameRef = useRef<HTMLSpanElement>(null);
  const [expanded, setExpanded] = useState(false);
  // Whether the collapsed name is actually cut off. Only re-measured while
  // collapsed: once expanded nothing is cut off, but the toggle has to stay
  // so it can be collapsed again.
  const [clamped, setClamped] = useState(false);

  useEffect(() => {
    if (expanded) return;
    const el = nameRef.current;
    if (!el) return;

    // Fires once on observe, and again whenever the width changes (window
    // resize, breakpoint change), which changes how much text fits.
    const observer = new ResizeObserver(() =>
      setClamped(el.scrollWidth - el.clientWidth > OVERFLOW_TOLERANCE_PX),
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, [expanded, name]);

  return (
    <div className="flex min-w-0 flex-1 items-start gap-2">
      <span
        ref={nameRef}
        className={`min-w-0 flex-1 [overflow-wrap:anywhere] ${expanded ? "" : "truncate"} ${className}`}
      >
        {name}
      </span>
      {(clamped || expanded) && (
        <button
          type="button"
          aria-expanded={expanded}
          aria-label={expanded ? "Prikaži manje" : "Prikaži ceo naziv"}
          title={expanded ? "Prikaži manje" : "Prikaži ceo naziv"}
          onClick={() => setExpanded((open) => !open)}
          className="flex size-7 shrink-0 items-center justify-center rounded-md border border-stone-300 hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:border-stone-600 dark:hover:bg-stone-700 dark:focus-visible:ring-offset-stone-800"
        >
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
            className={`size-4 ${expanded ? "rotate-180" : ""}`}
          >
            <polyline points="6 9 12 15 18 9" />
          </svg>
        </button>
      )}
    </div>
  );
}
