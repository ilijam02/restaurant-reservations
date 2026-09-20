"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { CancelDialog } from "@/components/reservations-list";
import { requestRefunds } from "@/lib/payments";
import { createClient } from "@/lib/supabase/client";

// The owner's "cancel everything that's still cancellable" for one restaurant,
// mainly so it can then be deleted (a restaurant with an active reservation
// can't be). `cancellableCount` and `ongoingCount` come from
// restaurant_deletion_plan(); the RPC re-validates everything itself.
export function CancelAllReservations({
  restaurantId,
  restaurantName,
  cancellableCount,
  ongoingCount,
}: {
  restaurantId: string;
  restaurantName: string;
  cancellableCount: number;
  ongoingCount: number;
}) {
  const router = useRouter();
  const [confirming, setConfirming] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Set when fewer were cancelled than were on offer (one changed under the
  // page). Kept in state - not derived from the refreshed count - so it
  // survives the button disappearing once nothing is left to cancel.
  const [notice, setNotice] = useState<string | null>(null);

  if (cancellableCount === 0 && !notice) return null;

  async function handleConfirm() {
    const requested = cancellableCount;
    setConfirming(false);
    setError(null);
    setNotice(null);
    setLoading(true);

    const supabase = createClient();
    const { data: cancelled, error: rpcError } = await supabase.rpc("cancel_all_active_reservations", {
      p_restaurant_id: restaurantId,
    });

    let refundNotice = "";
    if (!rpcError && typeof cancelled === "number" && cancelled > 0) {
      // Cancelling only queues refunds for paid orders (the owner cancelling
      // always refunds); this sends them to Stripe. A failure leaves them
      // "refund pending" - retryable from the reservation lists.
      const refunds = await requestRefunds();
      if ("error" in refunds || refunds.failed > 0) {
        refundNotice = " Povraćaj novca za neke porudžbine nije uspeo i biće ponovo pokušan - proverite listu rezervacija.";
      }
    }

    setLoading(false);
    if (rpcError) {
      setError(rpcError.code === "P0001" ? rpcError.message : "Otkazivanje nije uspelo. Pokušajte ponovo.");
    } else if (typeof cancelled === "number" && cancelled < requested) {
      const skipped = requested - cancelled;
      setNotice(
        `Otkazano: ${cancelled} od ${requested}. Rezervacije koje nisu otkazane (${skipped}) su se u međuvremenu promenile (npr. gost je već seo).${refundNotice}`,
      );
    } else if (refundNotice) {
      setNotice(refundNotice.trim());
    }

    // Refresh on failure too: the list may have changed under this page.
    router.refresh();
  }

  const description =
    `Otkazati sve rezervacije (${cancellableCount}) u restoranu ${restaurantName} koje još nisu u toku? ` +
    "Porudžbine će biti otkazane zajedno sa rezervacijama, a novac za plaćene porudžbine biće vraćen gostima. " +
    "To se ne može poništiti.";

  return (
    <>
      <div className="w-full max-w-lg space-y-2" inert={confirming}>
        {cancellableCount > 0 && (
          <button
            type="button"
            disabled={loading}
            onClick={() => setConfirming(true)}
            className="rounded-md border border-stone-300 px-3 py-2 text-sm text-danger hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700"
          >
            {loading ? "Otkazivanje..." : `Otkaži sve rezervacije (${cancellableCount})`}
          </button>
        )}
        {notice && (
          <p role="status" className="text-sm text-amber-700 dark:text-warning">
            {notice}
          </p>
        )}
        {error && (
          <p role="alert" className="text-sm text-red-600 dark:text-red-400">
            {error}
          </p>
        )}
      </div>

      {confirming && (
        <CancelDialog
          label="Potvrda otkazivanja svih rezervacija"
          description={description}
          warning={
            ongoingCount > 0
              ? `Rezervacije koje su već u toku (${ongoingCount}) neće biti otkazane - njih osoblje mora da završi.`
              : null
          }
          onConfirm={handleConfirm}
          onClose={() => setConfirming(false)}
        />
      )}
    </>
  );
}
