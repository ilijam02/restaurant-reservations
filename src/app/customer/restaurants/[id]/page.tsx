import { notFound } from "next/navigation";
import { ReservationForm } from "@/components/reservation-form";
import { createClient } from "@/lib/supabase/server";

export default async function CustomerRestaurantPage({
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
    .select("id, name")
    .eq("restaurant_id", id)
    .order("name");

  // Only tables on a currently-active layout are actually bookable -
  // create_reservation() enforces the same rule server-side.
  const { data: tables } = await supabase
    .from("tables")
    .select("id, name, seats, section_id, layouts!inner(is_active)")
    .eq("restaurant_id", id)
    .eq("layouts.is_active", true)
    .order("name");

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <h1 className="text-3xl font-bold">{restaurant.name}</h1>
      <ReservationForm
        restaurant={restaurant}
        hours={hours ?? []}
        sections={sections ?? []}
        tables={tables ?? []}
      />
    </main>
  );
}
