import Link from "next/link";
import { notFound } from "next/navigation";
import { AppHeader } from "@/components/app-header";
import { FavoriteButton } from "@/components/favorite-button";
import { MenuBrowser } from "@/components/menu-browser";
import { RestaurantViewTracker } from "@/components/restaurant-view-tracker";
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

  const { data: restaurant } = await supabase.from("restaurants").select("id, name, address, latitude").eq("id", id).is("archived_at", null).single();

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

  // RLS limits favorites to the caller's own rows, so this is "is it mine".
  const { data: favorite } = await supabase.from("favorites").select("restaurant_id").eq("restaurant_id", id).maybeSingle();

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/customer" />
      {/* Pinned to the top-right corner on the same line as AppHeader's back
          button (fixed top-4, h-10). The button is styled like the header's; the
          address is deliberately plain text (bg-background only keeps menu
          cards from showing through it while scrolling). left-32 keeps it clear of
          the header's own buttons; the wrapper ignores clicks so it never
          blocks anything in the gap between the two. */}
      {(restaurant.address || restaurant.latitude !== null) && (
        <div className="pointer-events-none fixed top-4 right-4 left-32 z-40 flex h-10 items-center justify-end gap-2">
          {restaurant.address && (
            <p className="pointer-events-auto min-w-0 truncate bg-background px-1 text-stone-600 dark:text-stone-400">
              {restaurant.address}
            </p>
          )}
          {/* Longitude is always set together with latitude (DB constraint). */}
          {restaurant.latitude !== null && (
            <Link
              href={mapHrefForRestaurant(restaurant.id)}
              className="pointer-events-auto flex h-10 shrink-0 items-center rounded-md border border-stone-300 bg-white px-3 text-sm text-stone-900 hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:hover:bg-stone-700 dark:focus-visible:ring-offset-stone-900"
            >
              Otvori na mapi
            </Link>
          )}
        </div>
      )}
      <RestaurantViewTracker restaurantId={id} />
      <div className="flex flex-wrap items-center justify-center gap-3">
        <h1 className="text-3xl font-bold">{restaurant.name}</h1>
        <FavoriteButton restaurantId={id} initialIsFavorite={!!favorite} />
      </div>
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
