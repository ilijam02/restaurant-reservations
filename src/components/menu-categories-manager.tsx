"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export type MenuCategoryRow = { id: string; name: string; display_order: number };

const SAVE_ERROR = "Čuvanje kategorije nije uspelo. Pokušajte ponovo.";
const DUPLICATE_NAME_ERROR = "Kategorija sa ovim nazivom već postoji.";

export function MenuCategoriesManager({
  restaurantId,
  categories,
}: {
  restaurantId: string;
  categories: MenuCategoryRow[];
}) {
  const router = useRouter();
  const [newName, setNewName] = useState("");
  const [pendingId, setPendingId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleRename(id: string, name: string, original: string) {
    const trimmed = name.trim();
    if (!trimmed || trimmed === original) return;

    setError(null);
    setPendingId(id);
    const supabase = createClient();
    const { error } = await supabase.from("menu_categories").update({ name: trimmed }).eq("id", id);
    setPendingId(null);

    if (error) {
      setError(error.code === "23505" ? DUPLICATE_NAME_ERROR : SAVE_ERROR);
      return;
    }
    router.refresh();
  }

  async function handleMove(index: number, direction: -1 | 1) {
    const other = categories[index + direction];
    const current = categories[index];
    if (!other) return;

    setError(null);
    setPendingId(current.id);
    const supabase = createClient();
    const [{ error: currentError }, { error: otherError }] = await Promise.all([
      supabase.from("menu_categories").update({ display_order: other.display_order }).eq("id", current.id),
      supabase.from("menu_categories").update({ display_order: current.display_order }).eq("id", other.id),
    ]);
    setPendingId(null);

    if (currentError || otherError) {
      setError(SAVE_ERROR);
      return;
    }
    router.refresh();
  }

  async function handleDelete(id: string) {
    setError(null);
    setPendingId(id);
    const supabase = createClient();
    const { error } = await supabase.from("menu_categories").delete().eq("id", id);
    setPendingId(null);

    if (error) {
      setError(SAVE_ERROR);
      return;
    }
    router.refresh();
  }

  async function handleAdd() {
    const trimmed = newName.trim();
    if (!trimmed) return;

    setError(null);
    setAdding(true);
    const supabase = createClient();
    const nextOrder = categories.length ? Math.max(...categories.map((c) => c.display_order)) + 1 : 0;
    const { error } = await supabase
      .from("menu_categories")
      .insert({ restaurant_id: restaurantId, name: trimmed, display_order: nextOrder });
    setAdding(false);

    if (error) {
      setError(error.code === "23505" ? DUPLICATE_NAME_ERROR : SAVE_ERROR);
      return;
    }
    setNewName("");
    router.refresh();
  }

  return (
    <div className="space-y-3">
      {categories.length === 0 ? (
        <p className="text-sm text-stone-600 dark:text-stone-400">Trenutno nema kategorija.</p>
      ) : (
        <ul className="space-y-2">
          {categories.map((category, index) => (
            <li key={category.id} className="flex items-center gap-2">
              <div className="flex shrink-0 flex-col">
                <button
                  type="button"
                  aria-label="Pomeri gore"
                  disabled={index === 0 || pendingId === category.id}
                  onClick={() => handleMove(index, -1)}
                  className="rounded-t-md border border-b-0 border-stone-300 px-1.5 text-xs hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-40 dark:border-stone-600 dark:hover:bg-stone-700"
                >
                  ▲
                </button>
                <button
                  type="button"
                  aria-label="Pomeri dole"
                  disabled={index === categories.length - 1 || pendingId === category.id}
                  onClick={() => handleMove(index, 1)}
                  className="rounded-b-md border border-stone-300 px-1.5 text-xs hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-40 dark:border-stone-600 dark:hover:bg-stone-700"
                >
                  ▼
                </button>
              </div>
              <label htmlFor={`category-name-${category.id}`} className="sr-only">
                Naziv kategorije
              </label>
              <input
                id={`category-name-${category.id}`}
                defaultValue={category.name}
                disabled={pendingId === category.id}
                onBlur={(event) => handleRename(category.id, event.target.value, category.name)}
                className="flex-1 rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent disabled:opacity-60 dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100"
              />
              <button
                type="button"
                onClick={() => handleDelete(category.id)}
                disabled={pendingId === category.id}
                className="shrink-0 rounded-md border border-stone-300 px-3 py-2 text-sm text-red-600 hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
              >
                Ukloni
              </button>
            </li>
          ))}
        </ul>
      )}

      <div className="flex items-center gap-2">
        <label htmlFor="new-category-name" className="sr-only">
          Naziv nove kategorije
        </label>
        <input
          id="new-category-name"
          placeholder="Nova kategorija"
          value={newName}
          onChange={(event) => setNewName(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              handleAdd();
            }
          }}
          className="flex-1 rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
        />
        <button
          type="button"
          onClick={handleAdd}
          disabled={adding || !newName.trim()}
          className="shrink-0 rounded-md border border-stone-300 px-3 py-2 text-sm hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700"
        >
          Dodaj kategoriju
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
