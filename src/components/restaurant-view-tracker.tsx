"use client";

import { useEffect, useRef } from "react";
import { createClient } from "@/lib/supabase/client";
import { markSignalsChanged } from "@/lib/recommendation-signals";

// Records that the customer opened this restaurant's page, as a signal for the
// recommendations (record_restaurant_view()). It runs from an effect, not from
// the server-rendered page, so only a page the customer actually opened counts
// - a prefetch or a crawler that renders the page never runs it. The ref (per
// restaurant) keeps React Strict Mode's dev-only double mount from counting a
// visit twice. Best effort: a failure changes nothing the customer can see.
// The ranked list is told it is out of date, both now (in case the customer
// goes straight back) and once the view is stored.
export function RestaurantViewTracker({ restaurantId }: { restaurantId: string }) {
  const sentFor = useRef<string | null>(null);

  useEffect(() => {
    if (sentFor.current === restaurantId) return;
    sentFor.current = restaurantId;
    markSignalsChanged();
    // The Supabase builder only sends the request once it is awaited/then'd.
    createClient()
      .rpc("record_restaurant_view", { p_restaurant_id: restaurantId })
      .then(() => markSignalsChanged());
  }, [restaurantId]);

  return null;
}
