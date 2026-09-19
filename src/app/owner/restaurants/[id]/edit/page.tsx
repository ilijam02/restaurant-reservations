import { redirect } from "next/navigation";
import { AppHeader } from "@/components/app-header";
import { DeleteRestaurantSection } from "@/components/delete-restaurant-section";
import { EditRestaurantForm } from "@/components/edit-restaurant-form";
import { fetchDeletionPlan } from "@/lib/restaurant-deletion";
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
    .select("id, name, capacity, default_stay_minutes, image_url, address, latitude, longitude, owner_id")
    .eq("id", id)
    .is("archived_at", null)
    .single();

  // The restaurants SELECT policy is public (any authenticated user, needed
  // for browsing), so it doesn't stop us from reading another owner's
  // restaurant here - only the app-level check below does.
  if (!restaurant || restaurant.owner_id !== user!.id) {
    redirect("/owner");
  }

  // For the delete section below; without it (a failed lookup) the section is
  // simply left out rather than shown with made-up numbers.
  const deletionPlan = await fetchDeletionPlan(supabase, id);

  const { data: hours } = await supabase
    .from("restaurant_hours")
    .select("day_of_week, start_minute, end_minute")
    .eq("restaurant_id", id)
    .order("day_of_week");

  const { data: sections } = await supabase
    .from("sections")
    .select("id, name, capacity, color_index")
    .eq("restaurant_id", id)
    .order("name");

  const { data: layouts } = await supabase
    .from("layouts")
    .select("id, name, is_active")
    .eq("restaurant_id", id)
    .order("name");

  // Every layout's tables, not just the one open on the canvas - editing
  // happens inline for whichever layout the owner has selected in the
  // dropdown.
  const { data: tables } = await supabase
    .from("tables")
    .select("id, layout_id, name, seats, section_id, x, y, width, height")
    .eq("restaurant_id", id)
    .order("name");

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/owner" />
      <h1 className="text-3xl font-bold">Uredi restoran</h1>
      <EditRestaurantForm
        restaurant={restaurant}
        hours={hours ?? []}
        sections={sections ?? []}
        layouts={layouts ?? []}
        tables={tables ?? []}
      />
      {deletionPlan && (
        <DeleteRestaurantSection restaurantId={restaurant.id} restaurantName={restaurant.name} plan={deletionPlan} />
      )}
    </main>
  );
}
