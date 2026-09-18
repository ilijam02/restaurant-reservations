import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

export async function EmployeeStaffRestaurants() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: staffRows } = await supabase
    .from("restaurant_staff")
    .select("restaurants(id, name)")
    .eq("employee_id", user!.id)
    .eq("status", "accepted");

  const restaurants = ((staffRows ?? []) as unknown as { restaurants: { id: string; name: string } | null }[])
    .map((row) => row.restaurants)
    .filter((restaurant): restaurant is { id: string; name: string } => !!restaurant)
    .sort((a, b) => a.name.localeCompare(b.name));

  if (restaurants.length === 0) {
    return (
      <p className="text-stone-600 dark:text-stone-400">
        Trenutno niste zaposleni ni u jednom restoranu. Prijavite se preko menija.
      </p>
    );
  }

  return (
    <ul className="w-full max-w-sm space-y-2">
      {restaurants.map((restaurant) => (
        <li key={restaurant.id}>
          <Link
            href={`/employee/restaurants/${restaurant.id}`}
            className="block rounded-lg border border-stone-200 bg-white px-4 py-3 hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent dark:border-stone-700 dark:bg-stone-800 dark:hover:bg-stone-700"
          >
            {restaurant.name}
          </Link>
        </li>
      ))}
    </ul>
  );
}
