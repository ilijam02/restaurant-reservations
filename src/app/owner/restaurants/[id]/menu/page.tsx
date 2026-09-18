import { redirect } from "next/navigation";
import { AppHeader } from "@/components/app-header";
import { MenuCategoriesManager } from "@/components/menu-categories-manager";
import { MenuItemsManager } from "@/components/menu-items-manager";
import { OWNER_MENU_ITEMS } from "@/lib/owner-nav";
import { createClient } from "@/lib/supabase/server";

export default async function OwnerRestaurantMenuPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: restaurant } = await supabase
    .from("restaurants")
    .select("id, name, owner_id")
    .eq("id", id)
    .single();

  // The restaurants SELECT policy is public (any authenticated user, needed
  // for browsing), so it doesn't stop us from reading another owner's
  // restaurant here - only the app-level check below does.
  if (!restaurant || restaurant.owner_id !== user!.id) {
    redirect("/owner");
  }

  const { data: categories } = await supabase
    .from("menu_categories")
    .select("id, name, display_order")
    .eq("restaurant_id", id)
    .order("display_order");

  const { data: items } = await supabase
    .from("menu_items")
    .select(
      "id, category_id, name, description, price, is_available, display_order, options:menu_item_options(id, name, is_required, allow_multiple, display_order, choices:menu_item_option_choices(id, name, price_delta, display_order))",
    )
    .eq("restaurant_id", id)
    .order("display_order");

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/owner" menuItems={OWNER_MENU_ITEMS} />
      <h1 className="text-3xl font-bold">Meni - {restaurant.name}</h1>

      <div className="w-full max-w-2xl space-y-3 rounded-lg border border-stone-200 bg-white p-6 shadow-sm dark:border-stone-700 dark:bg-stone-800">
        <h2 className="text-xl font-semibold">Kategorije</h2>
        <MenuCategoriesManager restaurantId={id} categories={categories ?? []} />
      </div>

      <div className="w-full max-w-2xl">
        <MenuItemsManager restaurantId={id} categories={categories ?? []} items={items ?? []} />
      </div>
    </main>
  );
}
