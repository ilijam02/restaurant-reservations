"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type StaffRow = { id: string; name: string };

export function OwnerStaffManager({ applications, staff }: { applications: StaffRow[]; staff: StaffRow[] }) {
  const router = useRouter();
  const [pendingId, setPendingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function handleAccept(id: string) {
    setError(null);
    setPendingId(id);

    const supabase = createClient();
    const { error } = await supabase.from("restaurant_staff").update({ status: "accepted" }).eq("id", id);

    setPendingId(null);
    if (error) {
      setError("Prihvatanje prijave nije uspelo. Pokušajte ponovo.");
      return;
    }

    router.refresh();
  }

  async function handleRemove(id: string) {
    setError(null);
    setPendingId(id);

    const supabase = createClient();
    const { error } = await supabase.from("restaurant_staff").delete().eq("id", id);

    setPendingId(null);
    if (error) {
      setError("Radnja nije uspela. Pokušajte ponovo.");
      return;
    }

    router.refresh();
  }

  return (
    <div className="w-full max-w-sm space-y-8">
      <section className="space-y-2">
        <h2 className="text-xl font-semibold">Aktivne prijave</h2>
        {applications.length === 0 ? (
          <p className="text-stone-600 dark:text-stone-400">Trenutno nema aktivnih prijava.</p>
        ) : (
          <ul className="space-y-2">
            {applications.map((application) => (
              <li
                key={application.id}
                className="flex items-center justify-between gap-3 rounded-lg border border-stone-200 bg-white px-4 py-3 dark:border-stone-700 dark:bg-stone-800"
              >
                <span>{application.name}</span>
                <div className="flex shrink-0 gap-2">
                  <button
                    onClick={() => handleAccept(application.id)}
                    disabled={pendingId === application.id}
                    className="rounded-md bg-accent px-3 py-1 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
                  >
                    Prihvati
                  </button>
                  <button
                    onClick={() => handleRemove(application.id)}
                    disabled={pendingId === application.id}
                    className="rounded-md border border-stone-300 px-3 py-1 text-sm text-red-600 hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
                  >
                    Odbij
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="space-y-2">
        <h2 className="text-xl font-semibold">Osoblje</h2>
        {staff.length === 0 ? (
          <p className="text-stone-600 dark:text-stone-400">Trenutno nema zaposlenih.</p>
        ) : (
          <ul className="space-y-2">
            {staff.map((member) => (
              <li
                key={member.id}
                className="flex items-center justify-between gap-3 rounded-lg border border-stone-200 bg-white px-4 py-3 dark:border-stone-700 dark:bg-stone-800"
              >
                <span>{member.name}</span>
                <button
                  onClick={() => handleRemove(member.id)}
                  disabled={pendingId === member.id}
                  className="shrink-0 rounded-md border border-stone-300 px-3 py-1 text-sm text-red-600 hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
                >
                  Ukloni
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>

      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}
    </div>
  );
}
