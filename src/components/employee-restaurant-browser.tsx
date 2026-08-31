"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type Restaurant = { id: string; name: string };
type Application = { restaurant_id: string; status: "pending" | "accepted" };

export function EmployeeRestaurantBrowser({
  restaurants,
  applications,
}: {
  restaurants: Restaurant[];
  applications: Application[];
}) {
  const router = useRouter();
  const [query, setQuery] = useState("");
  const [pendingId, setPendingId] = useState<string | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});

  const statusByRestaurant = new Map(applications.map((application) => [application.restaurant_id, application.status]));

  async function handleApply(restaurantId: string) {
    setErrors((previous) => ({ ...previous, [restaurantId]: "" }));
    setPendingId(restaurantId);

    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    const { error } = await supabase
      .from("restaurant_staff")
      .insert({ restaurant_id: restaurantId, employee_id: user!.id, status: "pending" });

    setPendingId(null);
    if (error) {
      setErrors((previous) => ({ ...previous, [restaurantId]: "Prijava nije uspela. Pokušajte ponovo." }));
      return;
    }

    router.refresh();
  }

  async function handleCancel(restaurantId: string) {
    setErrors((previous) => ({ ...previous, [restaurantId]: "" }));
    setPendingId(restaurantId);

    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    const { error } = await supabase
      .from("restaurant_staff")
      .delete()
      .eq("restaurant_id", restaurantId)
      .eq("employee_id", user!.id);

    setPendingId(null);
    if (error) {
      setErrors((previous) => ({ ...previous, [restaurantId]: "Otkazivanje nije uspelo. Pokušajte ponovo." }));
      return;
    }

    router.refresh();
  }

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
          {filtered.map((restaurant) => {
            const status = statusByRestaurant.get(restaurant.id);
            const isPending = pendingId === restaurant.id;
            const error = errors[restaurant.id];

            return (
              <li
                key={restaurant.id}
                className="rounded-lg border border-stone-200 bg-white px-4 py-3 dark:border-stone-700 dark:bg-stone-800"
              >
                <div className="flex items-center justify-between gap-3">
                  <span>{restaurant.name}</span>

                  {status === "accepted" && (
                    <span className="shrink-0 rounded-full bg-success/10 px-3 py-1 text-sm font-medium text-success">
                      Zaposlen/a
                    </span>
                  )}

                  {status === "pending" && (
                    <button
                      onClick={() => handleCancel(restaurant.id)}
                      disabled={isPending}
                      className="shrink-0 rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700"
                    >
                      {isPending ? "Otkazivanje..." : "Otkaži prijavu"}
                    </button>
                  )}

                  {status === undefined && (
                    <button
                      onClick={() => handleApply(restaurant.id)}
                      disabled={isPending}
                      className="shrink-0 rounded-md bg-accent px-3 py-1 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
                    >
                      {isPending ? "Slanje..." : "Prijavi se"}
                    </button>
                  )}
                </div>

                {status === "pending" && (
                  <p className="mt-1 text-sm text-stone-600 dark:text-stone-400">Prijava na čekanju</p>
                )}

                {error && (
                  <p role="alert" className="mt-1 text-sm text-red-600 dark:text-red-400">
                    {error}
                  </p>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
