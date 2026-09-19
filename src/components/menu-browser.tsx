"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { MenuItemImage } from "@/components/menu-item-image";
import { CartSummary, cartTotal, formatPrice, type CartItem } from "@/components/cart-summary";

const UNCATEGORIZED_KEY = "__uncategorized";
const ADD_ERROR = "Dodavanje u korpu nije uspelo. Pokušajte ponovo.";

export type MenuOptionChoice = { id: string; name: string; price_delta: number };
export type MenuOptionGroup = {
  id: string;
  name: string;
  is_required: boolean;
  allow_multiple: boolean;
  choices: MenuOptionChoice[];
};
export type MenuItemRow = {
  id: string;
  category_id: string | null;
  name: string;
  description: string | null;
  price: number;
  image_url: string | null;
  is_available: boolean;
  options: MenuOptionGroup[];
};

// Which option group ids each choice belongs to still have their
// selection requirements satisfied - only used to block "Dodaj u korpu"
// client-side before the round trip; add_order_item() re-validates all of
// this server-side regardless.
function missingRequiredGroup(item: MenuItemRow, selections: Record<string, string[]>) {
  return item.options.find((group) => group.is_required && (selections[group.id]?.length ?? 0) === 0);
}

export function MenuBrowser({
  restaurantId,
  categories,
  items,
  initialOrderId,
  initialCartItems,
  otherDraftRestaurantName,
}: {
  restaurantId: string;
  categories: { id: string; name: string; display_order: number }[];
  items: MenuItemRow[];
  initialOrderId: string | null;
  initialCartItems: CartItem[];
  otherDraftRestaurantName: string | null;
}) {
  const router = useRouter();
  const [orderId, setOrderId] = useState(initialOrderId);
  const [cartItems, setCartItems] = useState<CartItem[]>(initialCartItems);
  // Returning to a restaurant with items already in the cart should show
  // the cart right away, not require re-discovering the toggle - a fresh,
  // empty cart still starts collapsed since there's nothing to show yet.
  const [cartOpen, setCartOpen] = useState(initialCartItems.length > 0);
  const [pendingItemId, setPendingItemId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // The cart bar is fixed to the bottom of the viewport and changes height
  // when the cart is expanded, so the space reserved under the last menu row
  // is measured from the bar itself instead of a fixed guess - otherwise an
  // expanded cart covers the last row even when scrolled all the way down.
  const cartBarRef = useRef<HTMLDivElement>(null);
  const [cartBarHeight, setCartBarHeight] = useState(0);
  useEffect(() => {
    const bar = cartBarRef.current;
    if (!bar) return;
    const observer = new ResizeObserver(() => setCartBarHeight(bar.offsetHeight));
    observer.observe(bar);
    return () => observer.disconnect();
  }, []);

  const [expanded, setExpanded] = useState<{ itemId: string; selections: Record<string, string[]>; quantity: number } | null>(
    null,
  );
  // Shown inline in the expanded modifier panel itself (right next to
  // "Dodaj u korpu") rather than in the general error block below the
  // whole item list, which can be scrolled far out of view by the time the
  // customer notices anything happened.
  const [optionError, setOptionError] = useState<string | null>(null);

  // Only relevant until the customer's cart on this page is actually
  // established (orderId set) - once it is, further adds never touch a
  // different restaurant's draft, so the dialog never needs to fire again.
  const [pendingReplace, setPendingReplace] = useState<{ menuItemId: string; choiceIds: string[]; quantity: number } | null>(
    null,
  );

  async function refreshCart(oid: string) {
    const supabase = createClient();
    const { data } = await supabase
      .from("order_items")
      .select("id, item_name, unit_price, quantity, choices:order_item_choices(option_name, choice_name, price_delta)")
      .eq("order_id", oid)
      .order("created_at");
    setCartItems((data as CartItem[] | null) ?? []);
  }

  async function doAdd(menuItemId: string, choiceIds: string[], quantity: number) {
    setError(null);
    const supabase = createClient();
    let oid = orderId;

    if (!oid) {
      const { data, error: startError } = await supabase.rpc("start_cart", { p_restaurant_id: restaurantId });
      if (startError || !data) {
        setError(ADD_ERROR);
        return;
      }
      oid = data.id;
      setOrderId(oid);
    }

    const { error: addError } = await supabase.rpc("add_order_item", {
      p_order_id: oid,
      p_menu_item_id: menuItemId,
      p_choice_ids: choiceIds,
      p_quantity: quantity,
    });

    if (addError) {
      setError(addError.message || ADD_ERROR);
      return;
    }

    await refreshCart(oid!);
    setExpanded(null);
    setCartOpen(true);
  }

  function performAdd(menuItemId: string, choiceIds: string[], quantity: number) {
    if (!orderId && otherDraftRestaurantName) {
      setPendingReplace({ menuItemId, choiceIds, quantity });
      return;
    }
    void doAdd(menuItemId, choiceIds, quantity);
  }

  function confirmReplace() {
    const pending = pendingReplace;
    setPendingReplace(null);
    if (pending) void doAdd(pending.menuItemId, pending.choiceIds, pending.quantity);
  }

  function openItem(item: MenuItemRow) {
    if (!item.is_available) return;
    setError(null);
    setOptionError(null);
    if (item.options.length === 0) {
      performAdd(item.id, [], 1);
      return;
    }
    setExpanded({ itemId: item.id, selections: {}, quantity: 1 });
  }

  function closeExpanded() {
    setExpanded(null);
    setOptionError(null);
  }

  function toggleChoice(group: MenuOptionGroup, choiceId: string) {
    setOptionError(null);
    setExpanded((prev) => {
      if (!prev) return prev;
      const current = prev.selections[group.id] ?? [];
      const next = group.allow_multiple
        ? current.includes(choiceId)
          ? current.filter((c) => c !== choiceId)
          : [...current, choiceId]
        : current.includes(choiceId)
          ? []
          : [choiceId];
      return { ...prev, selections: { ...prev.selections, [group.id]: next } };
    });
  }

  function submitExpanded(item: MenuItemRow) {
    if (!expanded) return;
    const missing = missingRequiredGroup(item, expanded.selections);
    if (missing) {
      setOptionError(`Grupa opcija "${missing.name}" je obavezna.`);
      return;
    }
    setOptionError(null);
    const choiceIds = Object.values(expanded.selections).flat();
    performAdd(item.id, choiceIds, expanded.quantity);
  }

  async function handleQuantityChange(itemId: string, quantity: number) {
    if (quantity < 1) {
      await handleRemove(itemId);
      return;
    }
    setPendingItemId(itemId);
    const supabase = createClient();
    const { error: updateError } = await supabase.from("order_items").update({ quantity }).eq("id", itemId);
    setPendingItemId(null);
    if (updateError) {
      setError(ADD_ERROR);
      return;
    }
    setCartItems((prev) => prev.map((i) => (i.id === itemId ? { ...i, quantity } : i)));
  }

  async function handleRemove(itemId: string) {
    setPendingItemId(itemId);
    const supabase = createClient();
    const { error: deleteError } = await supabase.from("order_items").delete().eq("id", itemId);
    setPendingItemId(null);
    if (deleteError) {
      setError(ADD_ERROR);
      return;
    }
    setCartItems((prev) => prev.filter((i) => i.id !== itemId));
  }

  const groups = [
    ...categories.map((category) => ({
      key: category.id,
      name: category.name,
      items: items.filter((item) => item.category_id === category.id),
    })),
    {
      key: UNCATEGORIZED_KEY,
      name: "Bez kategorije",
      items: items.filter((item) => item.category_id === null),
    },
  ].filter((group) => group.items.length > 0);

  const itemCount = cartItems.reduce((sum, item) => sum + item.quantity, 0);
  const total = cartTotal(cartItems);

  return (
    // pb-28 is only the first-paint fallback before the bar is measured.
    <div
      className="w-full max-w-5xl space-y-6 pb-28"
      style={cartBarHeight ? { paddingBottom: cartBarHeight + 48 } : undefined}
    >
      {groups.length === 0 ? (
        <p className="text-stone-600 dark:text-stone-400">Meni trenutno nema stavki.</p>
      ) : (
        groups.map((group) => (
          <section key={group.key} className="space-y-2">
            <h2 className="text-xl font-semibold">{group.name}</h2>
            {/* items-start so opening one card's option panel doesn't
                stretch the other cards in its row. */}
            <ul className="grid items-start gap-4 sm:grid-cols-2 md:grid-cols-3">
              {group.items.map((item) => (
                <li key={item.id}>
                  <div
                    className={`overflow-hidden rounded-lg border border-stone-200 bg-white dark:border-stone-700 dark:bg-stone-800 ${
                      item.is_available ? "" : "opacity-60"
                    }`}
                  >
                    <MenuItemImage
                      imageUrl={item.image_url}
                      alt={item.name}
                      className="aspect-video w-full object-cover"
                    />
                    <div className="space-y-2 px-4 py-3">
                      <div className="min-w-0">
                        <p className="font-medium">{item.name}</p>
                        {item.description && (
                          <p className="text-sm text-stone-600 dark:text-stone-400">{item.description}</p>
                        )}
                      </div>
                      <div className="flex items-center justify-between gap-2">
                        <p className="text-sm text-stone-600 dark:text-stone-400">
                          {item.is_available ? formatPrice(item.price) : "Nedostupno"}
                        </p>
                        <button
                          type="button"
                          disabled={!item.is_available}
                          onClick={() => (expanded?.itemId === item.id ? closeExpanded() : openItem(item))}
                          className="shrink-0 rounded-md bg-accent px-3 py-1.5 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
                        >
                          {expanded?.itemId === item.id ? "Zatvori" : "Dodaj"}
                        </button>
                      </div>
                    </div>
                  </div>

                  {expanded?.itemId === item.id && (
                    <div className="mt-2 space-y-3 rounded-lg border border-stone-200 bg-stone-50 p-4 dark:border-stone-700 dark:bg-stone-900/40">
                      {item.options.map((group) => (
                        <fieldset key={group.id} className="space-y-1.5">
                          <legend className="text-sm font-medium">
                            {group.name}
                            {group.is_required && <span className="text-red-600 dark:text-red-400"> *</span>}
                          </legend>
                          <div className="space-y-1">
                            {group.choices.map((choice) => {
                              const selected = (expanded.selections[group.id] ?? []).includes(choice.id);
                              return (
                                <label key={choice.id} className="flex items-center gap-2 text-sm">
                                  <input
                                    type={group.allow_multiple ? "checkbox" : "radio"}
                                    name={`group-${group.id}`}
                                    checked={selected}
                                    onChange={() => toggleChoice(group, choice.id)}
                                    className="size-4 accent-accent"
                                  />
                                  {choice.name}
                                  {choice.price_delta !== 0 && (
                                    <span className="text-stone-500 dark:text-stone-400">
                                      ({choice.price_delta > 0 ? "+" : ""}
                                      {formatPrice(choice.price_delta)})
                                    </span>
                                  )}
                                </label>
                              );
                            })}
                          </div>
                        </fieldset>
                      ))}

                      <div className="flex items-center gap-2">
                        <span className="text-sm font-medium">Količina</span>
                        <button
                          type="button"
                          aria-label="Smanji količinu"
                          disabled={expanded.quantity <= 1}
                          onClick={() => setExpanded((prev) => (prev ? { ...prev, quantity: prev.quantity - 1 } : prev))}
                          className="flex size-7 items-center justify-center rounded-md border border-stone-300 hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700"
                        >
                          −
                        </button>
                        <span className="w-5 text-center text-sm tabular-nums">{expanded.quantity}</span>
                        <button
                          type="button"
                          aria-label="Povećaj količinu"
                          onClick={() => setExpanded((prev) => (prev ? { ...prev, quantity: prev.quantity + 1 } : prev))}
                          className="flex size-7 items-center justify-center rounded-md border border-stone-300 hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
                        >
                          +
                        </button>
                      </div>

                      {optionError && (
                        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
                          {optionError}
                        </p>
                      )}

                      <button
                        type="button"
                        onClick={() => submitExpanded(item)}
                        className="w-full rounded-md bg-accent px-3 py-2 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-900"
                      >
                        Dodaj u korpu
                      </button>
                    </div>
                  )}
                </li>
              ))}
            </ul>
          </section>
        ))
      )}

      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}

      {pendingReplace && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4 dark:bg-black/60">
          <div className="w-full max-w-sm space-y-4 rounded-lg border border-stone-200 bg-white p-6 shadow-sm dark:border-stone-700 dark:bg-stone-800">
            <p>
              Dodavanje ove stavke će obrisati vašu trenutnu porudžbinu iz restorana &quot;{otherDraftRestaurantName}&quot;.
              Nastaviti?
            </p>
            <div className="flex gap-2">
              <button
                type="button"
                onClick={confirmReplace}
                className="flex-1 rounded-md bg-accent px-3 py-2 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
              >
                Nastavi
              </button>
              <button
                type="button"
                onClick={() => setPendingReplace(null)}
                className="flex-1 rounded-md border border-stone-300 px-3 py-2 text-sm hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
              >
                Otkaži
              </button>
            </div>
          </div>
        </div>
      )}

      <div
        ref={cartBarRef}
        className="fixed inset-x-0 bottom-0 z-40 border-t border-stone-200 bg-white p-4 dark:border-stone-700 dark:bg-stone-800"
      >
        <div className="mx-auto flex max-w-5xl flex-col gap-3">
          {cartOpen && (
            // 20% shorter than the default max-h-64 (16rem) - 12.8rem.
            <div className="max-h-[12.8rem] overflow-y-auto">
              <CartSummary
                items={cartItems}
                mode="editable"
                pendingItemId={pendingItemId}
                onQuantityChange={handleQuantityChange}
                onRemove={handleRemove}
              />
            </div>
          )}
          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={() => setCartOpen((open) => !open)}
              disabled={cartItems.length === 0}
              className="flex-1 rounded-md border border-stone-300 px-3 py-2 text-left text-sm hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700"
            >
              🛒 {itemCount} {itemCount === 1 ? "stavka" : "stavki"} · {formatPrice(total)}
            </button>
            <button
              type="button"
              onClick={() => router.push(`/customer/restaurants/${restaurantId}/reserve`)}
              className="shrink-0 rounded-md bg-accent px-4 py-2 text-accent-foreground hover:opacity-90 active:opacity-80 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
            >
              Rezerviši
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
