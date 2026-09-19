"use client";

import { useState, type FormEvent } from "react";
import { createClient } from "@/lib/supabase/client";
import { ImagePicker, UNCHANGED_IMAGE, type ImageChange } from "@/components/image-picker";
import { MenuItemImage } from "@/components/menu-item-image";
import { MENU_ITEM_IMAGE_MAX_DIMENSION, removeStoredImage, uploadRestaurantImage } from "@/lib/image-upload";

export type MenuItemOptionChoiceRow = { id: string; name: string; price_delta: number; display_order: number };
export type MenuItemOptionRow = {
  id: string;
  name: string;
  is_required: boolean;
  allow_multiple: boolean;
  display_order: number;
  choices: MenuItemOptionChoiceRow[];
};
export type MenuItemRow = {
  id: string;
  category_id: string | null;
  name: string;
  description: string | null;
  price: number;
  image_url: string | null;
  is_available: boolean;
  display_order: number;
  options: MenuItemOptionRow[];
};

type DraftChoice = { key: string; name: string; priceDelta: string };
type DraftOption = { key: string; name: string; isRequired: boolean; allowMultiple: boolean; choices: DraftChoice[] };

const SAVE_ERROR = "Čuvanje stavke nije uspelo. Pokušajte ponovo.";

// Widthless so it can be combined with a sizing class (flex-1, w-28, ...)
// without conflicting with it - INPUT_CLASSES below adds w-full for the
// common case of a field that isn't sharing a flex row with another input.
const INPUT_FIELD_CLASSES =
  "rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500";
const INPUT_CLASSES = `w-full ${INPUT_FIELD_CLASSES}`;

function emptyChoice(): DraftChoice {
  return { key: crypto.randomUUID(), name: "", priceDelta: "0" };
}

function emptyOption(): DraftOption {
  return { key: crypto.randomUUID(), name: "", isRequired: false, allowMultiple: false, choices: [emptyChoice()] };
}

export function MenuItemEditor({
  restaurantId,
  categories,
  item,
  nextDisplayOrder,
  onSaved,
  onCancel,
}: {
  restaurantId: string;
  categories: { id: string; name: string }[];
  item: MenuItemRow | null;
  // Only used for a new item - one past the highest existing display_order
  // across the restaurant's items, so a freshly added item sorts after
  // everything else instead of tying at the column's default of 0 (which
  // left insertion order unstable across reloads once more than one item
  // existed without ever being reordered).
  nextDisplayOrder?: number;
  onSaved: () => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState(item?.name ?? "");
  const [description, setDescription] = useState(item?.description ?? "");
  const [price, setPrice] = useState(item ? item.price.toString() : "");
  const [categoryId, setCategoryId] = useState(item?.category_id ?? "");
  const [isAvailable, setIsAvailable] = useState(item?.is_available ?? true);
  const [imageChange, setImageChange] = useState<ImageChange>(UNCHANGED_IMAGE);
  const [options, setOptions] = useState<DraftOption[]>(() =>
    item
      ? item.options.map((o) => ({
          key: o.id,
          name: o.name,
          isRequired: o.is_required,
          allowMultiple: o.allow_multiple,
          choices: o.choices.length
            ? o.choices.map((c) => ({ key: c.id, name: c.name, priceDelta: c.price_delta.toString() }))
            : [emptyChoice()],
        }))
      : [],
  );
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function updateOption(key: string, patch: Partial<DraftOption>) {
    setOptions((prev) => prev.map((o) => (o.key === key ? { ...o, ...patch } : o)));
  }

  function updateChoice(optionKey: string, choiceKey: string, patch: Partial<DraftChoice>) {
    setOptions((prev) =>
      prev.map((o) =>
        o.key === optionKey ? { ...o, choices: o.choices.map((c) => (c.key === choiceKey ? { ...c, ...patch } : c)) } : o,
      ),
    );
  }

  function addOption() {
    setOptions((prev) => [...prev, emptyOption()]);
  }

  function removeOption(key: string) {
    setOptions((prev) => prev.filter((o) => o.key !== key));
  }

  function addChoice(optionKey: string) {
    setOptions((prev) => prev.map((o) => (o.key === optionKey ? { ...o, choices: [...o.choices, emptyChoice()] } : o)));
  }

  function removeChoice(optionKey: string, choiceKey: string) {
    setOptions((prev) =>
      prev.map((o) => (o.key === optionKey ? { ...o, choices: o.choices.filter((c) => c.key !== choiceKey) } : o)),
    );
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSaving(true);

    const supabase = createClient();

    // The new image goes up first so its URL can be part of the same row
    // write; the old one is only deleted after that write succeeds, so a
    // failed save never leaves the item pointing at a deleted image.
    let uploadedUrl: string | null = null;
    if (imageChange.kind === "replace") {
      const uploaded = await uploadRestaurantImage(supabase, restaurantId, imageChange.blob);
      if ("error" in uploaded) {
        setSaving(false);
        setError(uploaded.error);
        return;
      }
      uploadedUrl = uploaded.url;
    }

    const itemPayload = {
      restaurant_id: restaurantId,
      category_id: categoryId || null,
      name: name.trim(),
      description: description.trim() || null,
      price: Number(price),
      is_available: isAvailable,
      // Left out entirely when unchanged, so an edit never touches the column.
      ...(imageChange.kind === "replace" ? { image_url: uploadedUrl } : {}),
      ...(imageChange.kind === "remove" ? { image_url: null } : {}),
    };

    const { data: savedItem, error: itemError } = item
      ? await supabase.from("menu_items").update(itemPayload).eq("id", item.id).select("id").single()
      : await supabase
          .from("menu_items")
          .insert({ ...itemPayload, display_order: nextDisplayOrder ?? 0 })
          .select("id")
          .single();

    if (itemError || !savedItem) {
      await removeStoredImage(supabase, uploadedUrl);
      setSaving(false);
      setError(SAVE_ERROR);
      return;
    }

    if (imageChange.kind !== "unchanged") await removeStoredImage(supabase, item?.image_url);

    const itemId = savedItem.id;

    // Options/choices are synced wholesale (delete then reinsert) rather
    // than diffed - simple and cheap given the small counts expected per
    // item, and deleting an option cascades its choices at the DB level.
    if (item) {
      const { error: deleteOptionsError } = await supabase
        .from("menu_item_options")
        .delete()
        .eq("menu_item_id", itemId);

      if (deleteOptionsError) {
        setSaving(false);
        setError(SAVE_ERROR);
        return;
      }
    }

    const cleanOptions = options
      .map((o) => ({ ...o, name: o.name.trim(), choices: o.choices.filter((c) => c.name.trim()) }))
      .filter((o) => o.name && o.choices.length > 0);

    if (cleanOptions.length) {
      const { data: insertedOptions, error: optionsError } = await supabase
        .from("menu_item_options")
        .insert(
          cleanOptions.map((o, index) => ({
            menu_item_id: itemId,
            name: o.name,
            is_required: o.isRequired,
            allow_multiple: o.allowMultiple,
            display_order: index,
          })),
        )
        .select("id");

      if (optionsError || !insertedOptions) {
        setSaving(false);
        setError(SAVE_ERROR);
        return;
      }

      const choiceRows = cleanOptions.flatMap((o, index) =>
        o.choices.map((c, choiceIndex) => ({
          option_id: insertedOptions[index].id,
          name: c.name.trim(),
          price_delta: c.priceDelta ? Number(c.priceDelta) : 0,
          display_order: choiceIndex,
        })),
      );

      const { error: choicesError } = await supabase.from("menu_item_option_choices").insert(choiceRows);
      if (choicesError) {
        setSaving(false);
        setError(SAVE_ERROR);
        return;
      }
    }

    setSaving(false);
    onSaved();
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="space-y-4 rounded-lg border border-stone-200 bg-stone-50 p-4 dark:border-stone-700 dark:bg-stone-900/40"
    >
      <div className="space-y-1">
        <label htmlFor="item-name" className="block text-sm font-medium">
          Naziv
        </label>
        <input id="item-name" required value={name} onChange={(e) => setName(e.target.value)} className={INPUT_CLASSES} />
      </div>

      <div className="space-y-1">
        <label htmlFor="item-description" className="block text-sm font-medium">
          Opis
        </label>
        <textarea
          id="item-description"
          rows={2}
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          className={INPUT_CLASSES}
        />
      </div>

      <ImagePicker
        label="Slika"
        currentUrl={item?.image_url ?? null}
        value={imageChange}
        onChange={setImageChange}
        maxDimension={MENU_ITEM_IMAGE_MAX_DIMENSION}
        disabled={saving}
        previewClassName="aspect-video h-20 shrink-0 rounded-md object-cover"
        renderImage={(imageUrl, className) => <MenuItemImage imageUrl={imageUrl} alt="Slika stavke" className={className} />}
      />

      <div className="flex gap-3">
        <div className="flex-1 space-y-1">
          <label htmlFor="item-price" className="block text-sm font-medium">
            Cena (RSD)
          </label>
          <input
            id="item-price"
            required
            type="number"
            min={0}
            step="0.01"
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            className={INPUT_CLASSES}
          />
        </div>

        <div className="flex-1 space-y-1">
          <label htmlFor="item-category" className="block text-sm font-medium">
            Kategorija
          </label>
          <select id="item-category" value={categoryId} onChange={(e) => setCategoryId(e.target.value)} className={INPUT_CLASSES}>
            <option value="">Bez kategorije</option>
            {categories.map((category) => (
              <option key={category.id} value={category.id}>
                {category.name}
              </option>
            ))}
          </select>
        </div>
      </div>

      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={isAvailable}
          onChange={(e) => setIsAvailable(e.target.checked)}
          className="size-4 rounded border-stone-300 accent-accent dark:border-stone-600"
        />
        Dostupno
      </label>

      <div className="space-y-3">
        <h3 className="text-sm font-medium">Opcije (npr. veličina, dodaci)</h3>
        {options.length === 0 && <p className="text-sm text-stone-600 dark:text-stone-400">Nema opcija za ovu stavku.</p>}
        {options.map((option) => (
          <div key={option.key} className="space-y-2 rounded-md border border-stone-200 bg-white p-3 dark:border-stone-700 dark:bg-stone-800">
            <div className="flex items-center gap-2">
              <label htmlFor={`option-name-${option.key}`} className="sr-only">
                Naziv grupe opcija
              </label>
              <input
                id={`option-name-${option.key}`}
                required
                placeholder="Naziv grupe (npr. Veličina)"
                value={option.name}
                onChange={(e) => updateOption(option.key, { name: e.target.value })}
                className={`${INPUT_FIELD_CLASSES} min-w-0 flex-1`}
              />
              <button
                type="button"
                onClick={() => removeOption(option.key)}
                className="shrink-0 rounded-md border border-stone-300 px-3 py-2 text-sm text-red-600 hover:bg-stone-100 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
              >
                Ukloni grupu
              </button>
            </div>

            <div className="flex gap-4 text-sm">
              <label className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={option.isRequired}
                  onChange={(e) => updateOption(option.key, { isRequired: e.target.checked })}
                  className="size-4 rounded border-stone-300 accent-accent dark:border-stone-600"
                />
                Obavezno
              </label>
              <label className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={option.allowMultiple}
                  onChange={(e) => updateOption(option.key, { allowMultiple: e.target.checked })}
                  className="size-4 rounded border-stone-300 accent-accent dark:border-stone-600"
                />
                Višestruki izbor
              </label>
            </div>

            <div className="space-y-2 pl-2">
              {option.choices.map((choice) => (
                <div key={choice.key} className="flex items-center gap-2">
                  <label htmlFor={`choice-name-${choice.key}`} className="sr-only">
                    Naziv izbora
                  </label>
                  <input
                    id={`choice-name-${choice.key}`}
                    required
                    placeholder="Izbor (npr. Velika)"
                    value={choice.name}
                    onChange={(e) => updateChoice(option.key, choice.key, { name: e.target.value })}
                    className={`${INPUT_FIELD_CLASSES} min-w-0 flex-1`}
                  />
                  <label htmlFor={`choice-price-${choice.key}`} className="sr-only">
                    Doplata
                  </label>
                  <input
                    id={`choice-price-${choice.key}`}
                    type="number"
                    step="0.01"
                    placeholder="Doplata"
                    value={choice.priceDelta}
                    onChange={(e) => updateChoice(option.key, choice.key, { priceDelta: e.target.value })}
                    className={`${INPUT_FIELD_CLASSES} w-28 shrink-0`}
                  />
                  <button
                    type="button"
                    onClick={() => removeChoice(option.key, choice.key)}
                    className="shrink-0 rounded-md border border-stone-300 px-2 py-2 text-sm text-red-600 hover:bg-stone-100 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
                  >
                    Ukloni
                  </button>
                </div>
              ))}
              <button
                type="button"
                onClick={() => addChoice(option.key)}
                className="rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
              >
                Dodaj izbor
              </button>
            </div>
          </div>
        ))}
        <button
          type="button"
          onClick={addOption}
          className="rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
        >
          Dodaj grupu opcija
        </button>
      </div>

      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}

      <div className="flex gap-2">
        <button
          type="submit"
          disabled={saving}
          className="rounded-md bg-accent px-4 py-2 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-stone-50 dark:focus-visible:ring-offset-stone-900"
        >
          {saving ? "Čuvanje..." : "Sačuvaj stavku"}
        </button>
        <button
          type="button"
          onClick={onCancel}
          disabled={saving}
          className="rounded-md border border-stone-300 px-4 py-2 text-sm hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700"
        >
          Otkaži
        </button>
      </div>
    </form>
  );
}
