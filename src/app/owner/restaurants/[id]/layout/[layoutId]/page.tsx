import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { TableLayoutEditor } from "@/components/table-layout-editor";

export default async function OwnerRestaurantLayoutPage({
  params,
}: {
  params: Promise<{ id: string; layoutId: string }>;
}) {
  const { id, layoutId } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: restaurant } = await supabase
    .from("restaurants")
    .select("id, name, current_layout_id")
    .eq("id", id)
    .eq("owner_id", user!.id)
    .single();

  if (!restaurant) {
    notFound();
  }

  const { data: layout } = await supabase
    .from("layouts")
    .select("id, name")
    .eq("id", layoutId)
    .eq("restaurant_id", id)
    .single();

  if (!layout) {
    notFound();
  }

  const { data: sections } = await supabase
    .from("sections")
    .select("id, name, color_index")
    .eq("restaurant_id", id)
    .order("name");

  const { data: tables } = await supabase
    .from("tables")
    .select("id, name, seats, section_id, x, y, width, height")
    .eq("layout_id", layoutId)
    .order("name");

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <h1 className="text-3xl font-bold">
        {restaurant.name} — {layout.name}
      </h1>
      <TableLayoutEditor
        restaurantId={restaurant.id}
        layoutId={layout.id}
        isCurrentLayout={restaurant.current_layout_id === layout.id}
        sections={(sections ?? []).map((s) => ({ id: s.id, name: s.name, colorIndex: s.color_index }))}
        tables={tables ?? []}
      />
      <Link
        href={`/owner/restaurants/${restaurant.id}/edit`}
        className="text-sm font-medium text-stone-600 hover:underline dark:text-stone-400"
      >
        Nazad
      </Link>
    </main>
  );
}
