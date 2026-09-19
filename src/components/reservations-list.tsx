"use client";

import { useEffect, useId, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { CartSummary, type CartItem } from "@/components/cart-summary";
import { createClient } from "@/lib/supabase/client";

type ReservationStatus = "confirmed" | "preparing_order" | "order_prepared" | "ongoing" | "cancelled" | "completed" | "no_show";

// Mirrors is_active_reservation_status() in the DB (see
// 20260917140000_reservation_status_lifecycle.sql) - a reservation
// mid-service is still "current" from the customer's point of view too.
const ACTIVE_STATUSES: ReservationStatus[] = ["confirmed", "preparing_order", "order_prepared", "ongoing"];

// Mirrors cancel_reservation() in the DB (see 20260919100000_cancel_reservation.sql):
// only before the guest has been seated. Kept here only to decide whether to
// show the button - the RPC re-validates everything server-side regardless.
const CANCELLABLE_STATUSES: ReservationStatus[] = ["confirmed", "preparing_order", "order_prepared"];

export type ReservationRow = {
  id: string;
  customer_id: string;
  // Set by cancel_reservation() (see 20260919110000_cancel_reservation_audit.sql);
  // null on anything not cancelled, and on cancellations from before it existed.
  cancelled_by: string | null;
  party_size: number;
  starts_at: string;
  ends_at: string;
  status: ReservationStatus;
  restaurants: { name: string } | null;
  reservation_tables: { tables: { name: string } | null }[];
  reservation_sections: { party_size: number; sections: { name: string } | null }[];
  orders: { status: string; items: CartItem[] }[];
  // Only filled in for the owner's lists (see fetchOwnerReservations) - the
  // customer's own list has no use for their own name.
  customer_name?: string | null;
};

// Who is looking at the list. Same card layout for both; the owner's also
// names the customer and words the copy from the restaurant's side.
export type ReservationsPerspective = "customer" | "owner";

const STATUS_LABELS: Record<ReservationStatus, string> = {
  confirmed: "Potvrđena",
  preparing_order: "Priprema porudžbine",
  order_prepared: "Porudžbina spremna",
  ongoing: "U toku",
  completed: "Završena",
  cancelled: "Otkazana",
  no_show: "Nije se pojavio/la",
};

const STATUS_CLASSES: Record<ReservationStatus, string> = {
  confirmed: "bg-success/10 text-success",
  preparing_order: "bg-warning/10 text-amber-700 dark:text-warning",
  order_prepared: "bg-warning/10 text-amber-700 dark:text-warning",
  ongoing: "bg-success/10 text-success",
  completed: "bg-success/10 text-success",
  cancelled: "bg-danger/10 text-danger",
  no_show: "bg-danger/10 text-danger",
};

const COPY: Record<
  ReservationsPerspective,
  { empty: string; currentEmpty: string; pastEmpty: string }
> = {
  customer: {
    empty: "Trenutno nemate rezervacija.",
    currentEmpty: "Nemate predstojećih rezervacija.",
    pastEmpty: "Nemate prošlih rezervacija.",
  },
  owner: {
    empty: "Trenutno nema rezervacija.",
    currentEmpty: "Nema predstojećih rezervacija.",
    pastEmpty: "Nema prošlih rezervacija.",
  },
};

// Current vs past is purely time-based (ends_at against now), not otherwise
// status-driven - a cancelled-but-still-upcoming reservation is "past" even
// though its time hasn't arrived yet, since it's no longer something the
// customer is waiting on. See ISSUES.md's Decided note for the full
// reasoning. ACTIVE_STATUSES only narrows which statuses even count as
// "waiting on" in the first place (mid-service counts, terminal ones don't).
function isCurrent(reservation: ReservationRow, now: Date) {
  return ACTIVE_STATUSES.includes(reservation.status) && new Date(reservation.ends_at).getTime() >= now.getTime();
}

// Also requires ends_at not to have passed: between ends_at and the next
// auto-finish sweep a reservation still carries its old status, and
// cancel_reservation() rejects it.
function isCancellable(reservation: ReservationRow, now: Date) {
  return CANCELLABLE_STATUSES.includes(reservation.status) && new Date(reservation.ends_at).getTime() > now.getTime();
}

// Explicit timeZone, matching create_reservation()'s own hardcoded
// 'Europe/Belgrade' conversion (see create_reservations.sql) - without it,
// this would render in whatever timezone the customer's device happens to be
// set to instead of the restaurant's actual local time, and would also mismatch
// between server render and client hydration whenever they're in different zones.
function formatDateTime(iso: string) {
  const date = new Date(iso);
  const day = date.toLocaleDateString("sr-RS", { timeZone: "Europe/Belgrade" });
  const time = date.toLocaleTimeString("sr-RS", {
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "Europe/Belgrade",
  });
  return `${day} ${time}`;
}

function guestCountLabel(partySize: number) {
  return `${partySize} ${partySize === 1 ? "gost" : "gostiju"}`;
}

function seatingLabel(reservation: ReservationRow) {
  const tableNames = reservation.reservation_tables
    .map((rt) => rt.tables?.name)
    .filter((name): name is string => !!name);
  if (tableNames.length > 0) {
    return `Sto: ${tableNames.join(", ")}`;
  }

  const sectionNames = reservation.reservation_sections
    .map((rs) => rs.sections?.name)
    .filter((name): name is string => !!name);
  if (sectionNames.length > 0) {
    return `Deo restorana: ${sectionNames.join(", ")}`;
  }

  return null;
}

// The grey note on a cancelled card saying who cancelled, worded from the
// viewer's side. `cancelled_by = customer_id` means the customer cancelled,
// anything else is the restaurant's owner - so this needs no idea of who is
// currently signed in, only which list it's rendering. A null cancelled_by
// (cancelled before the column existed) gets the neutral wording.
function cancellationNote(reservation: ReservationRow, perspective: ReservationsPerspective) {
  if (reservation.status !== "cancelled") return null;
  if (!reservation.cancelled_by) return "Rezervacija je otkazana";

  const cancelledByCustomer = reservation.cancelled_by === reservation.customer_id;
  if (perspective === "customer") {
    return cancelledByCustomer ? "Otkazali ste rezervaciju" : "Rezervacija je otkazana";
  }
  return cancelledByCustomer ? "Gost je otkazao rezervaciju" : "Otkazali ste rezervaciju";
}

// Shown in the cancel confirmation when the kitchen has already started on
// (or finished) the order. The actual refund - or lack of one - isn't
// implemented yet (payment is still a placeholder, see ISSUES.md); this only
// tells the user up front what the policy will be.
function noRefundWarning(status: ReservationStatus) {
  if (status === "preparing_order") return "Upozorenje: porudžbina se već priprema - novac za nju neće biti vraćen.";
  if (status === "order_prepared") return "Upozorenje: porudžbina je već spremna - novac za nju neće biti vraćen.";
  return null;
}

// A real modal: focus moves into it (onto the safe "Ne, zadrži" choice),
// Tab stays inside it, Escape closes it, and focus goes back to whatever
// opened it afterwards. The list behind it is made inert by the caller.
function CancelDialog({
  description,
  warning,
  onConfirm,
  onClose,
}: {
  description: string;
  warning: string | null;
  onConfirm: () => void;
  onClose: () => void;
}) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const keepButtonRef = useRef<HTMLButtonElement>(null);
  const onCloseRef = useRef(onClose);
  const descriptionId = useId();
  // Captured at first render (the dialog only ever mounts in response to a
  // click), not inside the effect: React's dev-mode double-invoked effects
  // would otherwise re-read the activeElement after the first cleanup.
  const [opener] = useState(() => document.activeElement as HTMLElement | null);

  useEffect(() => {
    onCloseRef.current = onClose;
  });

  useEffect(() => {
    keepButtonRef.current?.focus();

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        event.preventDefault();
        onCloseRef.current();
        return;
      }
      if (event.key !== "Tab" || !dialogRef.current) return;

      const focusable = Array.from(dialogRef.current.querySelectorAll<HTMLElement>("button:not([disabled])"));
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement;
      if (!dialogRef.current.contains(active)) {
        event.preventDefault();
        first.focus();
      } else if (event.shiftKey && active === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && active === last) {
        event.preventDefault();
        first.focus();
      }
    }

    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      opener?.focus();
    };
  }, [opener]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-stone-900/50 p-4">
      <div
        ref={dialogRef}
        role="alertdialog"
        aria-modal="true"
        aria-label="Potvrda otkazivanja rezervacije"
        aria-describedby={descriptionId}
        className="w-full max-w-sm space-y-4 rounded-lg border border-stone-200 bg-white p-6 shadow-sm dark:border-stone-700 dark:bg-stone-800"
      >
        <div id={descriptionId} className="space-y-2">
          <p>{description}</p>
          {warning && <p className="text-sm font-medium text-amber-700 dark:text-warning">{warning}</p>}
        </div>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={onConfirm}
            className="flex-1 rounded-md bg-accent px-3 py-2 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
          >
            Da, otkaži
          </button>
          <button
            ref={keepButtonRef}
            type="button"
            onClick={onClose}
            className="flex-1 rounded-md border border-stone-300 px-3 py-2 text-sm hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent dark:border-stone-600 dark:hover:bg-stone-700"
          >
            Ne, zadrži
          </button>
        </div>
      </div>
    </div>
  );
}

function ReservationCard({
  reservation,
  perspective,
  cancellable,
  cancelling,
  error,
  onCancelRequest,
}: {
  reservation: ReservationRow;
  perspective: ReservationsPerspective;
  cancellable: boolean;
  cancelling: boolean;
  error?: string;
  onCancelRequest: (reservation: ReservationRow) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const order = reservation.orders[0];
  const hasOrder = !!order && order.items.length > 0;
  const cancelledNote = cancellationNote(reservation, perspective);
  const seating = seatingLabel(reservation);

  return (
    <li className="rounded-lg border border-stone-200 bg-white p-4 dark:border-stone-700 dark:bg-stone-800">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium">{reservation.restaurants?.name ?? "Restoran"}</p>
          {perspective === "owner" && (
            <p className="text-sm text-stone-600 dark:text-stone-400">
              Gost: {reservation.customer_name ?? "Nepoznat korisnik"}
            </p>
          )}
          <p className="text-sm text-stone-600 dark:text-stone-400">{formatDateTime(reservation.starts_at)}</p>
          <p className="text-sm text-stone-600 dark:text-stone-400">{guestCountLabel(reservation.party_size)}</p>
          {seating && <p className="text-sm text-stone-600 dark:text-stone-400">{seating}</p>}
        </div>
        <span className={`shrink-0 rounded-full px-3 py-1 text-sm font-medium ${STATUS_CLASSES[reservation.status]}`}>
          {STATUS_LABELS[reservation.status]}
        </span>
      </div>

      {(hasOrder || cancellable || cancelledNote) && (
        <div className="mt-3 flex flex-wrap items-center gap-2">
          {hasOrder && (
            <button
              type="button"
              aria-expanded={expanded}
              onClick={() => setExpanded((value) => !value)}
              className="rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent dark:border-stone-600 dark:hover:bg-stone-700"
            >
              {expanded ? "Sakrij porudžbinu" : "Prikaži porudžbinu"}
            </button>
          )}
          {cancelledNote && <span className="text-sm text-stone-600 dark:text-stone-400">{cancelledNote}</span>}
          {cancellable && (
            <button
              type="button"
              disabled={cancelling}
              onClick={() => onCancelRequest(reservation)}
              className="rounded-md border border-stone-300 px-3 py-1 text-sm text-danger hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700"
            >
              {cancelling ? "Otkazivanje..." : "Otkaži rezervaciju"}
            </button>
          )}
        </div>
      )}

      {error && (
        <p role="alert" className="mt-2 text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}

      {hasOrder && expanded && (
        <div className="mt-3 border-t border-stone-200 pt-3 dark:border-stone-700">
          <CartSummary items={order.items} mode="readonly" />
        </div>
      )}
    </li>
  );
}

// `now` is computed once by the server-component caller and passed down as a
// prop (rather than each client calling `new Date()` itself) so the initial
// server render and the client hydration pass classify reservations
// identically - a `new Date()` call here would risk a reservation flipping
// current/past between the two if its ends_at fell in between.
export function ReservationsList({
  reservations,
  now,
  perspective,
}: {
  reservations: ReservationRow[];
  now: string;
  perspective: ReservationsPerspective;
}) {
  const router = useRouter();
  const [cancellingId, setCancellingId] = useState<string | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [pendingCancel, setPendingCancel] = useState<ReservationRow | null>(null);

  const copy = COPY[perspective];

  async function handleCancel(reservationId: string) {
    setErrors((previous) => ({ ...previous, [reservationId]: "" }));
    setCancellingId(reservationId);

    const supabase = createClient();
    const { error } = await supabase.rpc("cancel_reservation", { p_reservation_id: reservationId });

    setCancellingId(null);
    if (error) {
      // The RPC's own messages (raised with the default P0001) are already
      // user-facing Serbian; anything else (network, permission) isn't.
      const message = error.code === "P0001" ? error.message : "Otkazivanje nije uspelo. Pokušajte ponovo.";
      setErrors((previous) => ({ ...previous, [reservationId]: message }));
    }

    // Refresh on failure too: the usual reason is that the reservation
    // changed under this (stale) page - already cancelled, started, expired -
    // and the card should catch up rather than keep offering the button.
    router.refresh();
  }

  function confirmCancel() {
    if (!pendingCancel) return;
    const reservationId = pendingCancel.id;
    setPendingCancel(null);
    handleCancel(reservationId);
  }

  if (reservations.length === 0) {
    return <p className="text-stone-600 dark:text-stone-400">{copy.empty}</p>;
  }

  const nowDate = new Date(now);
  const current = reservations
    .filter((r) => isCurrent(r, nowDate))
    .sort((a, b) => new Date(a.starts_at).getTime() - new Date(b.starts_at).getTime());
  const past = reservations
    .filter((r) => !isCurrent(r, nowDate))
    .sort((a, b) => new Date(b.starts_at).getTime() - new Date(a.starts_at).getTime());

  function renderCard(reservation: ReservationRow) {
    return (
      <ReservationCard
        key={reservation.id}
        reservation={reservation}
        perspective={perspective}
        cancellable={isCancellable(reservation, nowDate)}
        cancelling={cancellingId === reservation.id}
        error={errors[reservation.id]}
        onCancelRequest={setPendingCancel}
      />
    );
  }

  return (
    <>
      <div className="w-full max-w-lg space-y-8" inert={pendingCancel !== null}>
        <section className="space-y-3">
          <h2 className="text-lg font-semibold">Trenutne rezervacije</h2>
          {current.length === 0 ? (
            <p className="text-sm text-stone-600 dark:text-stone-400">{copy.currentEmpty}</p>
          ) : (
            <ul className="space-y-3">{current.map(renderCard)}</ul>
          )}
        </section>

        <section className="space-y-3">
          <h2 className="text-lg font-semibold">Prošle rezervacije</h2>
          {past.length === 0 ? (
            <p className="text-sm text-stone-600 dark:text-stone-400">{copy.pastEmpty}</p>
          ) : (
            <ul className="space-y-3">{past.map(renderCard)}</ul>
          )}
        </section>
      </div>

      {pendingCancel && (
        <CancelDialog
          description={
            (perspective === "owner"
              ? `Otkazati rezervaciju gosta ${pendingCancel.customer_name ?? "Nepoznat korisnik"} za ${formatDateTime(pendingCancel.starts_at)}?`
              : `Otkazati rezervaciju u restoranu ${pendingCancel.restaurants?.name ?? "Restoran"} za ${formatDateTime(pendingCancel.starts_at)}?`) +
            (pendingCancel.orders.length > 0 ? " Porudžbina će biti otkazana zajedno sa rezervacijom." : "") +
            " To se ne može poništiti."
          }
          warning={noRefundWarning(pendingCancel.status)}
          onConfirm={confirmCancel}
          onClose={() => setPendingCancel(null)}
        />
      )}
    </>
  );
}
