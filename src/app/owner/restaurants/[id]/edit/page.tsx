import { redirect } from "next/navigation";
import { EditRestaurantForm } from "@/components/edit-restaurant-form";
import { createClient } from "@/lib/supabase/server";

export default async function EditRestaurantPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: restaurant } = await supabase
    .from("restaurants")
    .select("id, name, capacity, default_stay_minutes, owner_id")
    .eq("id", id)
    .single();

  // The restaurants SELECT policy is public (any authenticated user, needed
  // for browsing), so it doesn't stop us from reading another owner's
  // restaurant here - only the app-level check below does.
  if (!restaurant || restaurant.owner_id !== user!.id) {
    redirect("/owner");
  }

  const { data: hours } = await supabase
    .from("restaurant_hours")
    .select("day_of_week, start_minute, end_minute")
    .eq("restaurant_id", id)
    .order("day_of_week");

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <h1 className="text-3xl font-bold">Uredi restoran</h1>
      <EditRestaurantForm restaurant={restaurant} hours={hours ?? []} />
    </main>
  );
}
