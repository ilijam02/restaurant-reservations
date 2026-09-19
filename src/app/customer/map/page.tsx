import { AppHeader } from "@/components/app-header";
import { RestaurantMap, type MapRestaurant } from "@/components/restaurant-map";
import { createClient } from "@/lib/supabase/server";

export default async function CustomerMapPage({
  searchParams,
}: {
  searchParams: Promise<{ restaurant?: string | string[] }>;
}) {
  const { restaurant } = await searchParams;
  const focusId = typeof restaurant === "string" ? restaurant : null;

  const supabase = await createClient();
  const { data } = await supabase
    .from("restaurants")
    .select("id, name, address, latitude, longitude")
    .not("latitude", "is", null)
    .not("longitude", "is", null)
    .order("name");

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-4 p-6 pt-16">
      <AppHeader backHref="/customer" />
      <h1 className="sr-only">Mapa</h1>
      <RestaurantMap restaurants={(data ?? []) as MapRestaurant[]} focusId={focusId} />
    </main>
  );
}
