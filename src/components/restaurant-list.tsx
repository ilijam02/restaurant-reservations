import { createClient } from "@/lib/supabase/server";
import { RestaurantBrowser } from "@/components/restaurant-browser";

export async function RestaurantList() {
  const supabase = await createClient();
  const { data: restaurants } = await supabase
    .from("restaurants")
    .select("id, name, image_url")
    .order("name");

  return <RestaurantBrowser restaurants={restaurants ?? []} />;
}
