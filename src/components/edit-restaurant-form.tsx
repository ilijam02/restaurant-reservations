"use client";

import { useState, type FormEvent } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { RestaurantHoursCalendar, type HourBlock } from "@/components/restaurant-hours-calendar";

type Restaurant = {
  id: string;
  name: string;
  capacity: number | null;
  default_stay_minutes: number;
};

type HoursRow = {
  day_of_week: number;
  start_minute: number;
  end_minute: number;
};

function initialBlocks(hours: HoursRow[]): HourBlock[] {
  return hours.map((h) => ({
    id: crypto.randomUUID(),
    dayOfWeek: h.day_of_week,
    start: h.start_minute,
    end: h.end_minute,
  }));
}

export function EditRestaurantForm({
  restaurant,
  hours,
}: {
  restaurant: Restaurant;
  hours: HoursRow[];
}) {
  const router = useRouter();
  const [name, setName] = useState(restaurant.name);
  const [capacity, setCapacity] = useState(restaurant.capacity?.toString() ?? "");
  const [defaultStayMinutes, setDefaultStayMinutes] = useState(
    restaurant.default_stay_minutes.toString(),
  );
  const [blocks, setBlocks] = useState<HourBlock[]>(() => initialBlocks(hours));
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setLoading(true);

    const supabase = createClient();

    const { error: restaurantError } = await supabase
      .from("restaurants")
      .update({
        name,
        capacity: capacity ? Number(capacity) : null,
        default_stay_minutes: Number(defaultStayMinutes),
      })
      .eq("id", restaurant.id);

    if (restaurantError) {
      setLoading(false);
      setError("Čuvanje izmena nije uspelo. Pokušajte ponovo.");
      return;
    }

    const { error: deleteError } = await supabase
      .from("restaurant_hours")
      .delete()
      .eq("restaurant_id", restaurant.id);

    const { error: insertError } = deleteError
      ? { error: deleteError }
      : blocks.length === 0
        ? { error: null }
        : await supabase.from("restaurant_hours").insert(
            blocks.map((b) => ({
              restaurant_id: restaurant.id,
              day_of_week: b.dayOfWeek,
              start_minute: b.start,
              end_minute: b.end,
            })),
          );

    setLoading(false);
    if (insertError) {
      setError("Čuvanje radnog vremena nije uspelo. Pokušajte ponovo.");
      return;
    }

    router.push("/owner");
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="w-full max-w-2xl space-y-6 rounded-lg border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-700 dark:bg-stone-800"
    >
      <div className="space-y-1">
        <label htmlFor="name" className="block text-sm font-medium">
          Naziv restorana
        </label>
        <input
          id="name"
          required
          value={name}
          onChange={(event) => setName(event.target.value)}
          className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
        />
      </div>

      <div className="grid grid-cols-2 gap-4">
        <div className="space-y-1">
          <label htmlFor="capacity" className="block text-sm font-medium">
            Kapacitet
          </label>
          <input
            id="capacity"
            type="number"
            min={1}
            value={capacity}
            onChange={(event) => setCapacity(event.target.value)}
            className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
          />
        </div>

        <div className="space-y-1">
          <label htmlFor="default-stay-minutes" className="block text-sm font-medium">
            Trajanje rezervacije (min)
          </label>
          <input
            id="default-stay-minutes"
            type="number"
            min={1}
            required
            value={defaultStayMinutes}
            onChange={(event) => setDefaultStayMinutes(event.target.value)}
            className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
          />
        </div>
      </div>

      <div className="space-y-2">
        <h2 className="text-sm font-medium">Radno vreme</h2>
        <RestaurantHoursCalendar value={blocks} onChange={setBlocks} />
      </div>

      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}

      <div className="flex items-center gap-4">
        <button
          type="submit"
          disabled={loading}
          className="flex-1 rounded-md bg-accent px-3 py-2 text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
        >
          {loading ? "Čuvanje..." : "Sačuvaj izmene"}
        </button>
        <Link
          href="/owner"
          className="text-sm font-medium text-stone-600 hover:underline dark:text-stone-400"
        >
          Nazad
        </Link>
      </div>
    </form>
  );
}
