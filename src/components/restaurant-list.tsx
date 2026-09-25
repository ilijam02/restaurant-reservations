import { createClient } from "@/lib/supabase/server";
import { RestaurantBrowser } from "@/components/restaurant-browser";
import { RefreshWhenSignalsChange } from "@/components/refresh-when-signals-change";
import { describeOrdering, rankRestaurants, type Recommendation } from "@/lib/recommendations";

export async function RestaurantList() {
  const supabase = await createClient();
  const [{ data: restaurants }, { data: recommendationRows, error: recommendationError }] = await Promise.all([
    supabase.from("restaurants").select("id, name, image_url").is("archived_at", null).order("name"),
    supabase.rpc("recommend_restaurants"),
  ]);

  // The ranking is an enhancement: if the call fails, the list is simply the
  // alphabetical one it always was - but a failure is worth seeing in the logs.
  if (recommendationError) {
    console.error("recommend_restaurants failed:", recommendationError.code, recommendationError.message);
  }
  const recommendations = (recommendationRows as Recommendation[] | null) ?? null;

  return (
    <>
      <RefreshWhenSignalsChange />
      <RestaurantBrowser restaurants={rankRestaurants(restaurants ?? [], recommendations)} ordering={describeOrdering(recommendations)} />
    </>
  );
}
