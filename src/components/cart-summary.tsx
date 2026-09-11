export type CartItemChoice = { option_name: string; choice_name: string; price_delta: number };
export type CartItem = {
  id: string;
  item_name: string;
  unit_price: number;
  quantity: number;
  choices: CartItemChoice[];
};

export function formatPrice(price: number) {
  return `${price.toFixed(2)} RSD`;
}

export function cartTotal(items: CartItem[]) {
  return items.reduce((sum, item) => sum + item.unit_price * item.quantity, 0);
}

const ICON_BUTTON_CLASSES =
  "flex size-7 shrink-0 items-center justify-center rounded-md border border-stone-300 text-stone-700 hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent dark:border-stone-600 dark:text-stone-300 dark:hover:bg-stone-700";

// Shared between the menu page (editable: quantity +/-, remove) and the
// combined reservation+payment page (readonly: a fixed snapshot of what's
// about to be confirmed, with no controls of its own - see CLAUDE.md's
// "combined page shows the cart read-only" decision).
export function CartSummary({
  items,
  mode,
  pendingItemId,
  onQuantityChange,
  onRemove,
}: {
  items: CartItem[];
  mode: "editable" | "readonly";
  pendingItemId?: string | null;
  onQuantityChange?: (itemId: string, quantity: number) => void;
  onRemove?: (itemId: string) => void;
}) {
  if (items.length === 0) {
    return <p className="text-sm text-stone-600 dark:text-stone-400">Korpa je prazna.</p>;
  }

  return (
    <div className="space-y-3">
      <ul className="space-y-2">
        {items.map((item) => {
          const pending = pendingItemId === item.id;
          return (
            <li
              key={item.id}
              className="flex items-start justify-between gap-3 rounded-md border border-stone-200 bg-white p-3 dark:border-stone-700 dark:bg-stone-800"
            >
              <div className="min-w-0 flex-1">
                <p className="font-medium">{item.item_name}</p>
                {item.choices.length > 0 && (
                  <p className="text-xs text-stone-600 dark:text-stone-400">
                    {item.choices.map((c) => c.choice_name).join(", ")}
                  </p>
                )}
                <p className="text-sm text-stone-600 dark:text-stone-400">
                  {formatPrice(item.unit_price)} × {item.quantity}
                </p>
              </div>

              {mode === "editable" ? (
                <div className="flex shrink-0 items-center gap-2">
                  <div className="flex items-center gap-1">
                    <button
                      type="button"
                      aria-label="Smanji količinu"
                      disabled={pending}
                      onClick={() => onQuantityChange?.(item.id, item.quantity - 1)}
                      className={ICON_BUTTON_CLASSES}
                    >
                      −
                    </button>
                    <span className="w-5 text-center text-sm tabular-nums">{item.quantity}</span>
                    <button
                      type="button"
                      aria-label="Povećaj količinu"
                      disabled={pending}
                      onClick={() => onQuantityChange?.(item.id, item.quantity + 1)}
                      className={ICON_BUTTON_CLASSES}
                    >
                      +
                    </button>
                  </div>
                  <button
                    type="button"
                    disabled={pending}
                    onClick={() => onRemove?.(item.id)}
                    className="shrink-0 rounded-md border border-stone-300 px-2 py-1 text-xs text-red-600 hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
                  >
                    Ukloni
                  </button>
                </div>
              ) : (
                <p className="shrink-0 font-medium">{formatPrice(item.unit_price * item.quantity)}</p>
              )}
            </li>
          );
        })}
      </ul>
      <div className="flex items-center justify-between border-t border-stone-200 pt-2 text-sm font-semibold dark:border-stone-700">
        <span>Ukupno</span>
        <span>{formatPrice(cartTotal(items))}</span>
      </div>
    </div>
  );
}
