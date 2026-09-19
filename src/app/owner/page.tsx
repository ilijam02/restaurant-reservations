import Link from "next/link";
import { AppHeader } from "@/components/app-header";
import { CreateRestaurantForm } from "@/components/create-restaurant-form";
import { RestaurantImage } from "@/components/restaurant-image";
import { createClient } from "@/lib/supabase/server";

// Order matters: it's the order the buttons appear under each restaurant.
const OWNER_RESTAURANT_ACTIONS = [
  { label: "Rezervacije", segment: "reservations" },
  { label: "Meni", segment: "menu" },
  { label: "Osoblje", segment: "staff" },
  { label: "Uredi", segment: "edit" },
];

export default async function OwnerHomePage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: restaurants } = await supabase
    .from("restaurants")
    .select("id, name, image_url")
    .eq("owner_id", user!.id)
    .order("name");

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader />
      <h1 className="sr-only">Početna</h1>

      <CreateRestaurantForm />

      <div className="w-full max-w-lg space-y-2">
        <h2 className="text-xl font-semibold">Moji restorani</h2>
        {!restaurants || restaurants.length === 0 ? (
          <p className="text-stone-600 dark:text-stone-400">Još uvek nemate restorana.</p>
        ) : (
          <ul className="space-y-4">
            {restaurants.map((restaurant) => (
              <li
                key={restaurant.id}
                className="space-y-3 rounded-lg border border-stone-200 bg-white p-4 dark:border-stone-700 dark:bg-stone-800"
              >
                <h3 className="text-lg font-semibold">{restaurant.name}</h3>
                <RestaurantImage
                  imageUrl={restaurant.image_url}
                  alt=""
                  className="aspect-video w-full rounded-md object-cover"
                />
                <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                  {OWNER_RESTAURANT_ACTIONS.map((action) => (
                    <Link
                      key={action.segment}
                      href={`/owner/restaurants/${restaurant.id}/${action.segment}`}
                      className="rounded-md border border-stone-300 px-2 py-1.5 text-center text-sm hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent dark:border-stone-600 dark:hover:bg-stone-700"
                    >
                      {action.label}
                    </Link>
                  ))}
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </main>
  );
}
