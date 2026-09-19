import Link from "next/link";
import { AppHeader } from "@/components/app-header";
import { CreateRestaurantForm } from "@/components/create-restaurant-form";
import { RestaurantImage } from "@/components/restaurant-image";
import { createClient } from "@/lib/supabase/server";

// Order matters: it's the order the buttons appear under each restaurant.
// "Uredi" is a plain orange text link rather than an outlined button.
const OWNER_RESTAURANT_ACTIONS = [
  { label: "Rezervacije", segment: "reservations", accentText: false },
  { label: "Meni", segment: "menu", accentText: false },
  { label: "Osoblje", segment: "staff", accentText: false },
  { label: "Uredi", segment: "edit", accentText: true },
];

const ACTION_BASE_CLASSES =
  "rounded-md px-2 py-1.5 text-center text-sm focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent";
const ACTION_BUTTON_CLASSES = `${ACTION_BASE_CLASSES} border border-stone-300 hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700`;
// text-orange-700 (not text-accent) in light mode: the bright accent fill
// doesn't reach AA as small text on the light background - see CLAUDE.md.
const ACTION_TEXT_CLASSES = `${ACTION_BASE_CLASSES} font-medium text-orange-700 hover:underline dark:text-accent`;

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
                // Hovering the name/image link highlights the whole card, like
                // the customer and employee restaurant cards (which are single
                // links). The card itself can't be the link - it also holds
                // the action buttons below.
                className="overflow-hidden rounded-lg border border-stone-200 bg-white has-[[data-card-link]:hover]:border-accent dark:border-stone-700 dark:bg-stone-800"
              >
                {/* The whole name section and the image are one link to the
                    restaurant's reservations, the same place as the
                    "Rezervacije" button. */}
                <Link
                  data-card-link
                  href={`/owner/restaurants/${restaurant.id}/reservations`}
                  className="block focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-accent"
                >
                  <h3 className="px-4 py-1 text-2xl font-semibold">
                    {restaurant.name}
                  </h3>
                  <RestaurantImage imageUrl={restaurant.image_url} alt="" className="aspect-video w-full object-cover" />
                </Link>
                <div className="grid grid-cols-2 gap-2 px-4 py-2.5 sm:grid-cols-4">
                  {OWNER_RESTAURANT_ACTIONS.map((action) => (
                    <Link
                      key={action.segment}
                      href={`/owner/restaurants/${restaurant.id}/${action.segment}`}
                      className={action.accentText ? ACTION_TEXT_CLASSES : ACTION_BUTTON_CLASSES}
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
