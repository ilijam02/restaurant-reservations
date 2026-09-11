"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { MenuItemImage } from "@/components/menu-item-image";
import { MenuItemEditor, type MenuItemRow } from "@/components/menu-item-editor";

const SAVE_ERROR = "Radnja nije uspela. Pokušajte ponovo.";
const UNCATEGORIZED_KEY = "__uncategorized";

function formatPrice(price: number) {
  return `${price.toFixed(2)} RSD`;
}

export function MenuItemsManager({
  restaurantId,
  categories,
  items,
}: {
  restaurantId: string;
  categories: { id: string; name: string; display_order: number }[];
  items: MenuItemRow[];
}) {
  const router = useRouter();
  const [pendingId, setPendingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  // "new" for the add-item form, an item id for editing that item, or null
  // for nothing open - only one editor open at a time.
  const [openEditor, setOpenEditor] = useState<string | null>(null);

  async function handleToggleAvailable(item: MenuItemRow) {
    setError(null);
    setPendingId(item.id);
    const supabase = createClient();
    const { error } = await supabase.from("menu_items").update({ is_available: !item.is_available }).eq("id", item.id);
    setPendingId(null);

    if (error) {
      setError(SAVE_ERROR);
      return;
    }
    router.refresh();
  }

  async function handleDelete(id: string) {
    setError(null);
    setPendingId(id);
    const supabase = createClient();
    const { error } = await supabase.from("menu_items").delete().eq("id", id);
    setPendingId(null);

    if (error) {
      setError(SAVE_ERROR);
      return;
    }
    router.refresh();
  }

  function handleSaved() {
    setOpenEditor(null);
    router.refresh();
  }

  const groups = [
    ...categories.map((category) => ({
      key: category.id,
      name: category.name,
      categoryId: category.id as string | null,
      items: items.filter((item) => item.category_id === category.id),
    })),
    {
      key: UNCATEGORIZED_KEY,
      name: "Bez kategorije",
      categoryId: null,
      items: items.filter((item) => item.category_id === null),
    },
  ];

  return (
    <div className="w-full space-y-6">
      {groups.map((group) => (
        <section key={group.key} className="space-y-2">
          <h2 className="text-xl font-semibold">{group.name}</h2>

          {group.items.length === 0 ? (
            <p className="text-sm text-stone-600 dark:text-stone-400">Nema stavki u ovoj kategoriji.</p>
          ) : (
            <ul className="space-y-2">
              {group.items.map((item) => (
                <li key={item.id}>
                  <div className="flex items-center gap-3 rounded-lg border border-stone-200 bg-white p-3 dark:border-stone-700 dark:bg-stone-800">
                    <MenuItemImage
                      imageUrl={null}
                      alt={item.name}
                      className="size-12 shrink-0 rounded-md object-cover"
                    />
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-medium">{item.name}</p>
                      <p className="text-sm text-stone-600 dark:text-stone-400">{formatPrice(item.price)}</p>
                    </div>
                    <label className="flex shrink-0 items-center gap-1.5 text-xs text-stone-600 dark:text-stone-400">
                      <input
                        type="checkbox"
                        checked={item.is_available}
                        disabled={pendingId === item.id}
                        onChange={() => handleToggleAvailable(item)}
                        className="size-4 rounded border-stone-300 accent-accent dark:border-stone-600"
                      />
                      Dostupno
                    </label>
                    <button
                      type="button"
                      onClick={() => setOpenEditor(openEditor === item.id ? null : item.id)}
                      className="shrink-0 rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
                    >
                      Uredi
                    </button>
                    <button
                      type="button"
                      onClick={() => handleDelete(item.id)}
                      disabled={pendingId === item.id}
                      className="shrink-0 rounded-md border border-stone-300 px-3 py-1 text-sm text-red-600 hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
                    >
                      Ukloni
                    </button>
                  </div>

                  {openEditor === item.id && (
                    <div className="mt-2">
                      <MenuItemEditor
                        restaurantId={restaurantId}
                        categories={categories}
                        item={item}
                        onSaved={handleSaved}
                        onCancel={() => setOpenEditor(null)}
                      />
                    </div>
                  )}
                </li>
              ))}
            </ul>
          )}

          {openEditor === `new-${group.key}` ? (
            <MenuItemEditor
              restaurantId={restaurantId}
              categories={categories}
              item={null}
              defaultCategoryId={group.categoryId}
              nextDisplayOrder={items.length ? Math.max(...items.map((i) => i.display_order)) + 1 : 0}
              onSaved={handleSaved}
              onCancel={() => setOpenEditor(null)}
            />
          ) : (
            <button
              type="button"
              onClick={() => setOpenEditor(`new-${group.key}`)}
              className="rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
            >
              Dodaj stavku
            </button>
          )}
        </section>
      ))}

      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}
    </div>
  );
}
