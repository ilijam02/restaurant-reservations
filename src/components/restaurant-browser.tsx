"use client";

import { useState } from "react";
import Link from "next/link";
import { RestaurantImage } from "@/components/restaurant-image";

// The list arrives already in ranked order (see restaurant-list.tsx); `ordering`
// is the one line above it saying how much of that order is tailored to the
// customer.
type Restaurant = { id: string; name: string; image_url: string | null };

export function RestaurantBrowser({ restaurants, ordering }: { restaurants: Restaurant[]; ordering: string | null }) {
  const [query, setQuery] = useState("");

  if (restaurants.length === 0) {
    return <p className="text-stone-600 dark:text-stone-400">Trenutno nema registrovanih restorana.</p>;
  }

  const filtered = restaurants.filter((restaurant) =>
    restaurant.name.toLowerCase().includes(query.trim().toLowerCase()),
  );

  return (
    <div className="w-full max-w-5xl space-y-4">
      <input
        type="search"
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        placeholder="Pretraži restorane"
        aria-label="Pretraži restorane"
        className="mx-auto block w-full max-w-sm rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
      />
      {ordering && <p className="text-center text-sm text-stone-600 dark:text-stone-400">{ordering}</p>}

      {filtered.length === 0 ? (
        <p className="text-stone-600 dark:text-stone-400">Nema restorana koji odgovaraju pretrazi.</p>
      ) : (
        <ul className="grid gap-4 sm:grid-cols-2 md:grid-cols-3">
          {filtered.map((restaurant) => (
            <li key={restaurant.id}>
              <Link
                href={`/customer/restaurants/${restaurant.id}`}
                className="block overflow-hidden rounded-lg border border-stone-200 bg-white hover:border-accent dark:border-stone-700 dark:bg-stone-800"
              >
                <RestaurantImage imageUrl={restaurant.image_url} alt="" className="aspect-video w-full object-cover" />
                <span className="block px-4 py-1 text-lg">{restaurant.name}</span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
