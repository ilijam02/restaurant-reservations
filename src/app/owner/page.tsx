import Link from "next/link";
import { LogoutButton } from "@/components/logout-button";
import { CreateRestaurantForm } from "@/components/create-restaurant-form";
import { createClient } from "@/lib/supabase/server";

export default async function OwnerHomePage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: restaurants } = await supabase
    .from("restaurants")
    .select("id, name")
    .eq("owner_id", user!.id)
    .order("name");

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <h1 className="text-3xl font-bold">VLASNIK</h1>

      <CreateRestaurantForm />

      <div className="w-full max-w-sm space-y-2">
        <h2 className="text-xl font-semibold">Moji restorani</h2>
        {!restaurants || restaurants.length === 0 ? (
          <p className="text-stone-600 dark:text-stone-400">Još uvek nemate restorana.</p>
        ) : (
          <ul className="space-y-2">
            {restaurants.map((restaurant) => (
              <li
                key={restaurant.id}
                className="flex items-center justify-between gap-4 rounded-lg border border-stone-200 bg-white px-4 py-3 dark:border-stone-700 dark:bg-stone-800"
              >
                <span>{restaurant.name}</span>
                <Link
                  href={`/owner/restaurants/${restaurant.id}/edit`}
                  className="text-sm font-medium text-orange-700 hover:underline dark:text-accent"
                >
                  Uredi
                </Link>
              </li>
            ))}
          </ul>
        )}
      </div>

      <LogoutButton />
    </main>
  );
}
