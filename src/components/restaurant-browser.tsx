"use client";

import { useState } from "react";

type Restaurant = { id: string; name: string };

export function RestaurantBrowser({ restaurants }: { restaurants: Restaurant[] }) {
  const [query, setQuery] = useState("");

  if (restaurants.length === 0) {
    return <p className="text-stone-600 dark:text-stone-400">Trenutno nema registrovanih restorana.</p>;
  }

  const filtered = restaurants.filter((restaurant) =>
    restaurant.name.toLowerCase().includes(query.trim().toLowerCase()),
  );

  return (
    <div className="w-full max-w-sm space-y-4">
      <input
        type="search"
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        placeholder="Pretraži restorane"
        aria-label="Pretraži restorane"
        className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
      />

      {filtered.length === 0 ? (
        <p className="text-stone-600 dark:text-stone-400">Nema restorana koji odgovaraju pretrazi.</p>
      ) : (
        <ul className="space-y-2">
          {filtered.map((restaurant) => (
            <li
              key={restaurant.id}
              className="rounded-lg border border-stone-200 bg-white px-4 py-3 dark:border-stone-700 dark:bg-stone-800"
            >
              {restaurant.name}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
