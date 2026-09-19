"use client";

import { useId, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { deleteRestaurantAction } from "@/app/owner/restaurants/[id]/edit/actions";
import { pluralSr } from "@/lib/plural";
import type { DeletionPlan } from "@/lib/restaurant-deletion";

// What deleting does depends on whether the restaurant has reservation
// history - the database decides (see delete_restaurant()); this only
// describes it up front so the owner isn't surprised.
function Consequences({ plan }: { plan: DeletionPlan }) {
  if (plan.total_reservations === 0) {
    return (
      <p>
        Restoran će biti trajno obrisan, zajedno sa njegovim menijem ({plan.menu_item_count}{" "}
        {pluralSr(plan.menu_item_count, "stavka", "stavke", "stavki")}), rasporedom stolova ({plan.table_count}{" "}
        {pluralSr(plan.table_count, "sto", "stola", "stolova")}), prijavama i osobljem ({plan.staff_count}) i slikama.
      </p>
    );
  }

  return (
    <p>
      Restoran će nestati sa svih lista i više neće primati rezervacije, a osoblje ({plan.staff_count}) gubi pristup.
      Njegove prošle rezervacije ({plan.total_reservations}) ostaju sačuvane u istoriji gostiju.
    </p>
  );
}

export function DeleteRestaurantSection({
  restaurantId,
  restaurantName,
  plan,
}: {
  restaurantId: string;
  restaurantName: string;
  plan: DeletionPlan;
}) {
  const router = useRouter();
  const confirmId = useId();
  const [typedName, setTypedName] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const blocked = plan.active_reservations > 0;
  const nameMatches = typedName.trim() === restaurantName.trim();

  async function handleDelete() {
    if (!nameMatches || blocked) return;
    setError(null);
    setLoading(true);

    const result = await deleteRestaurantAction(restaurantId);

    if (!result.ok) {
      setLoading(false);
      setError(result.error);
      // The usual reason is that the restaurant changed under this (stale)
      // page - a new booking - so the section should catch up (and switch to
      // the blocked view if that's what happened).
      router.refresh();
      return;
    }

    router.push("/owner");
    router.refresh();
  }

  return (
    <section className="w-full max-w-3xl space-y-4 rounded-lg border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-700 dark:bg-stone-800">
      <h2 className="text-xl font-semibold text-red-600 dark:text-red-400">Brisanje restorana</h2>

      {blocked ? (
        <div className="space-y-2">
          <p className="text-red-600 dark:text-red-400">
            Restoran ima {plan.active_reservations}{" "}
            {pluralSr(plan.active_reservations, "aktivnu rezervaciju", "aktivne rezervacije", "aktivnih rezervacija")} i
            ne može biti obrisan dok ne budu otkazane ili završene.
          </p>
          <Link
            href={`/owner/restaurants/${restaurantId}/reservations`}
            className="inline-block text-sm font-medium text-orange-700 hover:underline focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent dark:text-accent"
          >
            Idi na rezervacije
          </Link>
        </div>
      ) : (
        <>
          <div className="space-y-2 text-stone-700 dark:text-stone-300">
            <Consequences plan={plan} />
            <p className="font-medium">Ovo se ne može poništiti.</p>
          </div>

          <div className="space-y-1">
            <label htmlFor={confirmId} className="block text-sm font-medium">
              Za potvrdu ukucajte naziv restorana: <span className="font-semibold">{restaurantName}</span>
            </label>
            <input
              id={confirmId}
              value={typedName}
              onChange={(event) => setTypedName(event.target.value)}
              autoComplete="off"
              disabled={loading}
              className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
            />
          </div>

          {error && (
            <p role="alert" className="text-red-600 dark:text-red-400">
              {error}
            </p>
          )}

          <button
            type="button"
            onClick={handleDelete}
            disabled={!nameMatches || loading}
            className="rounded-md bg-red-700 px-4 py-2 text-white hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-red-700 focus-visible:ring-offset-2 dark:bg-red-400 dark:text-stone-900 dark:focus-visible:ring-red-400 dark:focus-visible:ring-offset-stone-800"
          >
            {loading ? "Brisanje..." : "Obriši restoran"}
          </button>
        </>
      )}
    </section>
  );
}
