"use client";

import { useEffect, useRef, useState } from "react";
import { MenuItemImage } from "@/components/menu-item-image";
import { formatPrice } from "@/components/cart-summary";

// An owner can type a description as one long unbroken string (a URL, or
// just no spaces) - without this it would push out of the card, or be cut
// off with no way to read it. "anywhere" lets it wrap at any character.
const WRAP_LONG_WORDS = "[overflow-wrap:anywhere]";

// Sub-pixel rounding can make scroll and client sizes differ by a pixel
// without anything actually being cut off.
const OVERFLOW_TOLERANCE_PX = 1;

// Collapsed, the name and the description each take one line, and the
// description keeps its one-line height even when it's missing (min-h-5 =
// 1 x leading-5) - so every collapsed card in a grid row is the same height
// regardless of its text. Expanded, the text takes whatever
// space it needs and only this card grows (the grid aligns cards to the
// start of their row, so its neighbors keep their collapsed height).
export function MenuItemCard({
  name,
  description,
  price,
  imageUrl,
  isAvailable,
  actionLabel,
  onAction,
}: {
  name: string;
  description: string | null;
  price: number;
  imageUrl: string | null;
  isAvailable: boolean;
  actionLabel: string;
  onAction: () => void;
}) {
  const nameRef = useRef<HTMLParagraphElement>(null);
  const descriptionRef = useRef<HTMLParagraphElement>(null);
  const [textExpanded, setTextExpanded] = useState(false);
  // Whether the collapsed text is actually cut off. Only re-measured while
  // collapsed: once expanded nothing is cut off, but the toggle has to stay
  // so the card can be collapsed again.
  const [clamped, setClamped] = useState(false);

  useEffect(() => {
    if (textExpanded) return;
    const nameEl = nameRef.current;
    const descriptionEl = descriptionRef.current;

    const measure = () => {
      const nameCut = !!nameEl && nameEl.scrollWidth - nameEl.clientWidth > OVERFLOW_TOLERANCE_PX;
      const descriptionCut =
        !!descriptionEl && descriptionEl.scrollHeight - descriptionEl.clientHeight > OVERFLOW_TOLERANCE_PX;
      setClamped(nameCut || descriptionCut);
    };

    // Also fires once on observe, and again whenever the card's width
    // changes (window resize, breakpoint change), which changes how much
    // text fits.
    const observer = new ResizeObserver(measure);
    if (nameEl) observer.observe(nameEl);
    if (descriptionEl) observer.observe(descriptionEl);
    return () => observer.disconnect();
  }, [textExpanded, name, description]);

  return (
    <div
      className={`overflow-hidden rounded-lg border border-stone-200 bg-white dark:border-stone-700 dark:bg-stone-800 ${
        isAvailable ? "" : "opacity-60"
      }`}
    >
      <MenuItemImage imageUrl={imageUrl} alt={name} className="aspect-video w-full object-cover" />
      <div className="space-y-2 px-4 pt-1.5 pb-3">
        <div className="min-w-0">
          <p ref={nameRef} className={`font-medium ${WRAP_LONG_WORDS} ${textExpanded ? "" : "truncate"}`}>
            {name}
          </p>
          <p
            ref={descriptionRef}
            className={`text-sm leading-5 text-stone-600 dark:text-stone-400 ${WRAP_LONG_WORDS} ${
              textExpanded ? "" : "line-clamp-1 min-h-5"
            }`}
          >
            {description}
          </p>
        </div>
        <div className="flex items-center justify-between gap-2">
          <p className="text-sm text-stone-600 dark:text-stone-400">{isAvailable ? formatPrice(price) : "Nedostupno"}</p>
          <div className="flex shrink-0 items-center gap-2">
            {(clamped || textExpanded) && (
              <button
                type="button"
                aria-expanded={textExpanded}
                aria-label={textExpanded ? "Prikaži manje" : "Prikaži više"}
                title={textExpanded ? "Prikaži manje" : "Prikaži više"}
                onClick={() => setTextExpanded((open) => !open)}
                className="flex size-8 items-center justify-center rounded-md border border-stone-300 hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:border-stone-600 dark:hover:bg-stone-700 dark:focus-visible:ring-offset-stone-800"
              >
                <svg
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  aria-hidden="true"
                  className={`size-4 ${textExpanded ? "rotate-180" : ""}`}
                >
                  <polyline points="6 9 12 15 18 9" />
                </svg>
              </button>
            )}
            <button
              type="button"
              disabled={!isAvailable}
              onClick={onAction}
              className="rounded-md bg-accent px-3 py-1.5 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
            >
              {actionLabel}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
