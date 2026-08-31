"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export function CreateRestaurantForm() {
  const router = useRouter();
  const [name, setName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setLoading(true);

    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    const { error } = await supabase
      .from("restaurants")
      .insert({ name, owner_id: user!.id });

    setLoading(false);
    if (error) {
      setError("Kreiranje restorana nije uspelo. Pokušajte ponovo.");
      return;
    }

    setName("");
    router.refresh();
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="w-full max-w-sm space-y-4 rounded-lg border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-700 dark:bg-stone-800"
    >
      <h2 className="text-xl font-semibold">Dodaj restoran</h2>

      <div className="space-y-1">
        <label htmlFor="name" className="block text-sm font-medium">
          Naziv restorana
        </label>
        <input
          id="name"
          required
          value={name}
          onChange={(event) => setName(event.target.value)}
          className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
        />
      </div>

      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}

      <button
        type="submit"
        disabled={loading}
        className="w-full rounded-md bg-accent px-3 py-2 text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
      >
        {loading ? "Dodavanje..." : "Dodaj restoran"}
      </button>
    </form>
  );
}
