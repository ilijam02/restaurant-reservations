import { notFound } from "next/navigation";
import { AppHeader } from "@/components/app-header";
import { ReservationForm } from "@/components/reservation-form";
import type { CartItem } from "@/components/cart-summary";
import { createClient } from "@/lib/supabase/server";
import { CUSTOMER_MENU_ITEMS } from "@/lib/customer-nav";

export default async function ReserveRestaurantPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: restaurant } = await supabase
    .from("restaurants")
    .select("id, name, capacity, default_stay_minutes")
    .eq("id", id)
    .single();

  if (!restaurant) {
    notFound();
  }

  const { data: hours } = await supabase
    .from("restaurant_hours")
    .select("day_of_week, start_minute, end_minute")
    .eq("restaurant_id", id)
    .order("day_of_week");

  const { data: sections } = await supabase
    .from("sections")
    .select("id, name, color_index")
    .eq("restaurant_id", id)
    .order("name");

  const { data: layouts } = await supabase
    .from("layouts")
    .select("id, name")
    .eq("restaurant_id", id)
    .eq("is_active", true)
    .order("name");

  // Only tables on a currently-active layout are actually bookable -
  // create_reservation() enforces the same rule server-side.
  const { data: tables } = await supabase
    .from("tables")
    .select("id, name, seats, section_id, layout_id, x, y, width, height, layouts!inner(is_active)")
    .eq("restaurant_id", id)
    .eq("layouts.is_active", true)
    .order("name");

  // At most one row (RLS restricts orders to the caller's own regardless of
  // status, and a customer has at most one 'draft' at a time - see
  // start_cart()). Only treated as this page's cart if it's actually a draft
  // for *this* restaurant - a draft left over from browsing a different
  // restaurant's menu means "no cart here", not an error, matching the menu
  // page's own cross-restaurant handling.
  const { data: draftOrder } = await supabase
    .from("orders")
    .select(
      "id, restaurant_id, items:order_items(id, item_name, unit_price, quantity, choices:order_item_choices(option_name, choice_name, price_delta))",
    )
    .eq("status", "draft")
    .eq("restaurant_id", id)
    .maybeSingle();

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref={`/customer/restaurants/${id}`} menuItems={CUSTOMER_MENU_ITEMS} />
      <h1 className="text-3xl font-bold">{restaurant.name}</h1>
      <ReservationForm
        restaurant={restaurant}
        hours={hours ?? []}
        sections={sections ?? []}
        layouts={layouts ?? []}
        tables={tables ?? []}
        orderId={draftOrder?.id ?? null}
        cartItems={(draftOrder?.items as unknown as CartItem[] | undefined) ?? []}
      />
    </main>
  );
}
