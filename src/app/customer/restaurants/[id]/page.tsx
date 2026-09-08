import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

export default async function CustomerRestaurantPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: restaurant } = await supabase.from("restaurants").select("id, name").eq("id", id).single();

  if (!restaurant) {
    notFound();
  }

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <h1 className="text-3xl font-bold">{restaurant.name}</h1>
      <Link
        href={`/customer/restaurants/${id}/reserve`}
        className="rounded-md bg-accent px-4 py-2 text-accent-foreground hover:opacity-90 active:opacity-80 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-900"
      >
        Rezerviši
      </Link>
    </main>
  );
}
