"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";

export type LayoutOption = { id: string; name: string };

const DUPLICATE_NAME_ERROR = "Raspored sa ovim nazivom već postoji.";
const CREATE_ERROR = "Kreiranje rasporeda nije uspelo. Pokušajte ponovo.";
const DELETE_ERROR = "Brisanje rasporeda nije uspelo. Pokušajte ponovo.";

export function LayoutsEditor({
  restaurantId,
  value,
  onChange,
  currentId,
  onCurrentIdChange,
}: {
  restaurantId: string;
  value: LayoutOption[];
  onChange: (next: LayoutOption[]) => void;
  currentId: string | null;
  onCurrentIdChange: (id: string | null) => void;
}) {
  const [newName, setNewName] = useState("");
  const [creating, setCreating] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // A layout is created immediately (not staged with the rest of the
  // form) specifically so its "Uredi raspored" link works right away -
  // editing a layout's tables needs a real, saved layout to point at, and
  // waiting for the owner to also save name/hours/sections first would
  // block that. Choosing which layout is current still stays staged.
  async function addLayout() {
    const name = newName.trim();
    if (!name) return;
    setError(null);
    setCreating(true);

    const supabase = createClient();
    const { data, error: insertError } = await supabase
      .from("layouts")
      .insert({ restaurant_id: restaurantId, name })
      .select("id, name")
      .single();

    setCreating(false);
    if (insertError || !data) {
      setError(insertError?.code === "23505" ? DUPLICATE_NAME_ERROR : CREATE_ERROR);
      return;
    }

    onChange([...value, data]);
    onCurrentIdChange(data.id);
    setNewName("");
  }

  async function deleteCurrent() {
    if (!currentId) return;
    setError(null);
    setDeleting(true);

    const supabase = createClient();
    const { error: deleteError } = await supabase.from("layouts").delete().eq("id", currentId);

    setDeleting(false);
    if (deleteError) {
      setError(DELETE_ERROR);
      return;
    }

    onChange(value.filter((l) => l.id !== currentId));
    onCurrentIdChange(null);
  }

  return (
    <div className="space-y-2">
      {value.length === 0 ? (
        <p className="text-sm text-stone-600 dark:text-stone-400">Nema još rasporeda.</p>
      ) : (
        <div className="flex gap-2">
          <label htmlFor="current-layout" className="sr-only">
            Trenutni raspored
          </label>
          <select
            id="current-layout"
            value={currentId ?? ""}
            onChange={(event) => onCurrentIdChange(event.target.value)}
            className="flex-1 rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100"
          >
            <option value="" disabled>
              Izaberi raspored
            </option>
            {value.map((layout) => (
              <option key={layout.id} value={layout.id}>
                {layout.name}
              </option>
            ))}
          </select>
          {currentId && (
            <button
              type="button"
              onClick={deleteCurrent}
              disabled={deleting}
              className="shrink-0 rounded-md border border-stone-300 px-3 py-1 text-sm text-red-600 hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
            >
              {deleting ? "Brisanje..." : "Obriši raspored"}
            </button>
          )}
        </div>
      )}
      <div className="flex gap-2">
        <label htmlFor="new-layout-name" className="sr-only">
          Naziv novog rasporeda
        </label>
        <input
          id="new-layout-name"
          value={newName}
          onChange={(event) => setNewName(event.target.value)}
          placeholder="Naziv novog rasporeda"
          className="flex-1 rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
        />
        <button
          type="button"
          onClick={addLayout}
          disabled={creating}
          className="shrink-0 rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700"
        >
          {creating ? "Dodavanje..." : "Dodaj raspored"}
        </button>
      </div>
      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}
    </div>
  );
}
