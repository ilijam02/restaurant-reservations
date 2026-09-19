import Link from "next/link";
import { RestaurantImage } from "@/components/restaurant-image";
import { createClient } from "@/lib/supabase/server";

export async function EmployeeStaffRestaurants() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: staffRows } = await supabase
    .from("restaurant_staff")
    .select("restaurants(id, name, image_url)")
    .eq("employee_id", user!.id)
    .eq("status", "accepted");

  type StaffRestaurant = { id: string; name: string; image_url: string | null };
  const restaurants = ((staffRows ?? []) as unknown as { restaurants: StaffRestaurant | null }[])
    .map((row) => row.restaurants)
    .filter((restaurant): restaurant is StaffRestaurant => !!restaurant)
    .sort((a, b) => a.name.localeCompare(b.name));

  if (restaurants.length === 0) {
    return (
      <p className="text-stone-600 dark:text-stone-400">
        Trenutno niste zaposleni ni u jednom restoranu. Prijavite se preko menija.
      </p>
    );
  }

  return (
    <ul className="w-full max-w-md space-y-4">
      {restaurants.map((restaurant) => (
        <li key={restaurant.id}>
          <Link
            href={`/employee/restaurants/${restaurant.id}`}
            className="block overflow-hidden rounded-lg border border-stone-200 bg-white hover:border-accent focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent dark:border-stone-700 dark:bg-stone-800"
          >
            <RestaurantImage imageUrl={restaurant.image_url} alt="" className="aspect-video w-full object-cover" />
            <span className="block px-4 py-3 text-lg">{restaurant.name}</span>
          </Link>
        </li>
      ))}
    </ul>
  );
}
