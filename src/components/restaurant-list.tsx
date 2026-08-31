import { createClient } from "@/lib/supabase/server";

export async function RestaurantList() {
  const supabase = await createClient();
  const { data: restaurants } = await supabase
    .from("restaurants")
    .select("id, name")
    .order("name");

  if (!restaurants || restaurants.length === 0) {
    return <p className="text-stone-600 dark:text-stone-400">Trenutno nema registrovanih restorana.</p>;
  }

  return (
    <ul className="w-full max-w-sm space-y-2">
      {restaurants.map((restaurant) => (
        <li
          key={restaurant.id}
          className="rounded-lg border border-stone-200 bg-white px-4 py-3 dark:border-stone-700 dark:bg-stone-800"
        >
          {restaurant.name}
        </li>
      ))}
    </ul>
  );
}
