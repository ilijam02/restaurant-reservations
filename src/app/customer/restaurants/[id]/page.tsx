import Link from "next/link";
import { notFound } from "next/navigation";
import { AppHeader } from "@/components/app-header";
import { MenuBrowser } from "@/components/menu-browser";
import type { CartItem } from "@/components/cart-summary";
import { mapHrefForRestaurant } from "@/lib/map";
import { createClient } from "@/lib/supabase/server";

export default async function CustomerRestaurantPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: restaurant } = await supabase.from("restaurants").select("id, name, address, latitude").eq("id", id).single();

  if (!restaurant) {
    notFound();
  }

  const { data: categories } = await supabase
    .from("menu_categories")
    .select("id, name, display_order")
    .eq("restaurant_id", id)
    .order("display_order");

  const { data: items } = await supabase
    .from("menu_items")
    .select(
      "id, category_id, name, description, price, image_url, is_available, display_order, options:menu_item_options(id, name, is_required, allow_multiple, display_order, choices:menu_item_option_choices(id, name, price_delta, display_order))",
    )
    .eq("restaurant_id", id)
    .order("display_order");

  // At most one row - RLS on orders restricts select to the caller's own
  // orders regardless of status, and a customer has at most one 'draft' at
  // a time (see start_cart()). If it belongs to a different restaurant than
  // this page, it's surfaced as otherDraftRestaurantName instead of hydrating
  // the cart - MenuBrowser uses that to gate the replace-confirmation dialog.
  const { data: draftOrder } = await supabase
    .from("orders")
    .select(
      "id, restaurant_id, restaurants(name), items:order_items(id, item_name, unit_price, quantity, choices:order_item_choices(option_name, choice_name, price_delta))",
    )
    .eq("status", "draft")
    .maybeSingle();

  const isOwnRestaurantDraft = draftOrder?.restaurant_id === id;

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/customer" />
      <h1 className="text-3xl font-bold">{restaurant.name}</h1>
      {(restaurant.address || restaurant.latitude !== null) && (
        <div className="flex flex-col items-center gap-2">
          {restaurant.address && <p className="text-stone-600 dark:text-stone-400">{restaurant.address}</p>}
          {/* Longitude is always set together with latitude (DB constraint). */}
          {restaurant.latitude !== null && (
            <Link
              href={mapHrefForRestaurant(restaurant.id)}
              className="rounded-md border border-stone-300 px-3 py-1.5 text-sm hover:bg-stone-100 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent dark:border-stone-600 dark:hover:bg-stone-700"
            >
              Otvori na mapi
            </Link>
          )}
        </div>
      )}
      <MenuBrowser
        restaurantId={id}
        categories={categories ?? []}
        items={items ?? []}
        initialOrderId={isOwnRestaurantDraft ? draftOrder!.id : null}
        initialCartItems={isOwnRestaurantDraft ? ((draftOrder!.items as unknown as CartItem[]) ?? []) : []}
        otherDraftRestaurantName={
          draftOrder && !isOwnRestaurantDraft ? ((draftOrder.restaurants as unknown as { name: string } | null)?.name ?? null) : null
        }
      />
    </main>
  );
}
