import { createClient } from "@/lib/supabase/server";
import { RestaurantBrowser } from "@/components/restaurant-browser";

export async function RestaurantList() {
  const supabase = await createClient();
  const { data: restaurants } = await supabase
    .from("restaurants")
    .select("id, name, image_url")
    .is("archived_at", null)
    .order("name");

  return <RestaurantBrowser restaurants={restaurants ?? []} />;
}
