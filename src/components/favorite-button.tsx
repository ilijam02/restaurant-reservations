"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { markSignalsChanged } from "@/lib/recommendation-signals";

const FAVORITE_ERROR = "Izmena omiljenih nije uspela. Pokušajte ponovo.";

// The customer's "favorite" toggle for a restaurant: a row in `favorites`
// (own rows only, by RLS), which the recommendations count as a fairly strong
// signal. It is a toggle button in the ARIA sense: one constant label
// ("Omiljeno") and aria-pressed carrying the state, plus the heart's fill for
// sighted users - the label must not change with the state, or a screen reader
// announces a contradiction ("Dodaj u omiljene, pressed"). While a request is in
// flight it is aria-disabled rather than disabled, so it keeps keyboard focus.
export function FavoriteButton({ restaurantId, initialIsFavorite }: { restaurantId: string; initialIsFavorite: boolean }) {
  const [isFavorite, setIsFavorite] = useState(initialIsFavorite);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function toggle() {
    if (pending) return;
    setPending(true);
    setError(null);

    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) {
      setPending(false);
      setError(FAVORITE_ERROR);
      return;
    }

    const { error: writeError } = isFavorite
      ? await supabase.from("favorites").delete().eq("user_id", user.id).eq("restaurant_id", restaurantId)
      : await supabase.from("favorites").insert({ user_id: user.id, restaurant_id: restaurantId });

    setPending(false);
    // 23505: already a favorite (another tab got there first) - the state we
    // wanted, so not an error.
    if (writeError && writeError.code !== "23505") {
      setError(FAVORITE_ERROR);
      return;
    }
    setIsFavorite(!isFavorite);
    markSignalsChanged();
  }

  return (
    <div className="flex flex-col items-center gap-1">
      <button
        type="button"
        onClick={toggle}
        aria-pressed={isFavorite}
        aria-disabled={pending}
        aria-busy={pending}
        className="flex h-10 items-center gap-2 rounded-md border border-stone-300 bg-white px-3 text-sm text-stone-900 hover:bg-stone-100 aria-disabled:cursor-not-allowed aria-disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:hover:bg-stone-700 dark:focus-visible:ring-offset-stone-900"
      >
        <svg
          aria-hidden="true"
          viewBox="0 0 24 24"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          className={`h-5 w-5 ${isFavorite ? "fill-orange-700 stroke-orange-700 dark:fill-accent dark:stroke-accent" : "fill-none stroke-current"}`}
        >
          <path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z" />
        </svg>
        Omiljeno
      </button>
      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}
    </div>
  );
}
