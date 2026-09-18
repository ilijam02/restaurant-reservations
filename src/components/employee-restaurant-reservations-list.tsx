"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type ReservationStatus = "confirmed" | "preparing_order" | "order_prepared" | "ongoing" | "completed" | "no_show" | "cancelled";

export type EmployeeReservationRow = {
  id: string;
  party_size: number;
  starts_at: string;
  status: ReservationStatus;
  reservation_tables: { tables: { name: string } | null }[];
  reservation_sections: { sections: { name: string } | null }[];
  orders: { status: string }[];
};

const STATUS_LABELS: Record<ReservationStatus, string> = {
  confirmed: "Potvrđena",
  preparing_order: "Priprema porudžbine",
  order_prepared: "Porudžbina spremna",
  ongoing: "U toku",
  completed: "Završena",
  no_show: "Nije se pojavio/la",
  cancelled: "Otkazana",
};

const STATUS_CLASSES: Record<ReservationStatus, string> = {
  confirmed: "bg-success/10 text-success",
  preparing_order: "bg-warning/10 text-amber-700 dark:text-warning",
  order_prepared: "bg-warning/10 text-amber-700 dark:text-warning",
  ongoing: "bg-success/10 text-success",
  completed: "bg-success/10 text-success",
  no_show: "bg-danger/10 text-danger",
  cancelled: "bg-danger/10 text-danger",
};

// Explicit timeZone, matching create_reservation()'s own hardcoded
// 'Europe/Belgrade' conversion - without it this would render in whatever
// timezone the employee's device happens to be set to instead of the
// restaurant's actual local time.
function formatDateTime(iso: string) {
  const date = new Date(iso);
  const day = date.toLocaleDateString("sr-RS", { timeZone: "Europe/Belgrade" });
  const time = date.toLocaleTimeString("sr-RS", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Belgrade" });
  return `${day} ${time}`;
}

function guestCountLabel(partySize: number) {
  return `${partySize} ${partySize === 1 ? "gost" : "gostiju"}`;
}

function seatingLabel(reservation: EmployeeReservationRow) {
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

// Mirrors update_reservation_status()'s own transition graph (see
// 20260917140000_reservation_status_lifecycle.sql) - kept here only to
// decide which buttons to show, the RPC remains the actual authority and
// re-validates everything server-side regardless of what this renders.
function nextActions(
  reservation: EmployeeReservationRow,
  hasStarted: boolean,
  canMarkOngoing: boolean,
): { status: ReservationStatus; label: string }[] {
  const hasOrder = reservation.orders.length > 0;
  const ongoingAction = canMarkOngoing ? [{ status: "ongoing" as const, label: "Označi kao u toku" }] : [];
  const noShowAction = hasStarted ? [{ status: "no_show" as const, label: "Gost se nije pojavio/la" }] : [];

  switch (reservation.status) {
    case "confirmed":
      return [
        ...(hasOrder ? [{ status: "preparing_order" as const, label: "Počni pripremu porudžbine" }] : ongoingAction),
        ...noShowAction,
      ];
    case "preparing_order":
      return [{ status: "order_prepared", label: "Porudžbina je spremna" }];
    case "order_prepared":
      return [...ongoingAction, ...noShowAction];
    case "ongoing":
      return [{ status: "completed", label: "Završi rezervaciju" }];
    default:
      return [];
  }
}

// Mirrors update_reservation_status()'s early-start window (see
// 20260918130000_reservation_lifecycle_review_fixes.sql): a reservation can
// only be marked ongoing once it has started or within this long before.
const EARLY_START_WINDOW_MINUTES = 60;

function ReservationCard({
  reservation,
  now,
  pending,
  error,
  onTransition,
}: {
  reservation: EmployeeReservationRow;
  now: Date;
  pending: boolean;
  error?: string;
  onTransition: (reservation: EmployeeReservationRow, newStatus: ReservationStatus) => void;
}) {
  const hasStarted = new Date(reservation.starts_at).getTime() <= now.getTime();
  const withinStartWindow =
    new Date(reservation.starts_at).getTime() - now.getTime() <= EARLY_START_WINDOW_MINUTES * 60000;
  const canMarkOngoing = hasStarted || withinStartWindow;
  const seating = seatingLabel(reservation);
  const actions = nextActions(reservation, hasStarted, canMarkOngoing);
  const waitsForStartWindow =
    !canMarkOngoing &&
    ((reservation.status === "confirmed" && reservation.orders.length === 0) ||
      reservation.status === "order_prepared");

  return (
    <li className="rounded-lg border border-stone-200 bg-white p-4 dark:border-stone-700 dark:bg-stone-800">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium">{formatDateTime(reservation.starts_at)}</p>
          <p className="text-sm text-stone-600 dark:text-stone-400">{guestCountLabel(reservation.party_size)}</p>
          {seating && <p className="text-sm text-stone-600 dark:text-stone-400">{seating}</p>}
        </div>
        <span className={`shrink-0 rounded-full px-3 py-1 text-sm font-medium ${STATUS_CLASSES[reservation.status]}`}>
          {STATUS_LABELS[reservation.status]}
        </span>
      </div>

      {actions.length > 0 && (
        <div className="mt-3 flex flex-wrap gap-2">
          {actions.map((action) => (
            <button
              key={action.status}
              type="button"
              disabled={pending}
              onClick={() => onTransition(reservation, action.status)}
              className={
                action.status === "no_show"
                  ? "rounded-md border border-stone-300 px-3 py-1 text-sm text-danger hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700"
                  : "rounded-md bg-accent px-3 py-1 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
              }
            >
              {pending ? "Sačuvavanje..." : action.label}
            </button>
          ))}
        </div>
      )}

      {waitsForStartWindow && (
        <p className="mt-3 text-sm text-stone-600 dark:text-stone-400">
          Može se označiti kao u toku najviše {EARLY_START_WINDOW_MINUTES} minuta pre početka.
        </p>
      )}

      {error && (
        <p role="alert" className="mt-2 text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}
    </li>
  );
}

// `now` is computed once by the server-component caller and passed down as a
// prop, matching CustomerReservationsList's own convention, so the initial
// server render and the client hydration pass agree on which reservations
// have already started (relevant to the no_show button's timing gate).
export function EmployeeRestaurantReservationsList({ reservations, now }: { reservations: EmployeeReservationRow[]; now: string }) {
  const router = useRouter();
  const [pendingId, setPendingId] = useState<string | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [pendingEarlyStart, setPendingEarlyStart] = useState<EmployeeReservationRow | null>(null);

  async function handleTransition(reservationId: string, newStatus: ReservationStatus) {
    setErrors((previous) => ({ ...previous, [reservationId]: "" }));
    setPendingId(reservationId);

    const supabase = createClient();
    const { error } = await supabase.rpc("update_reservation_status", {
      p_reservation_id: reservationId,
      p_new_status: newStatus,
    });

    setPendingId(null);
    if (error) {
      setErrors((previous) => ({ ...previous, [reservationId]: error.message }));
      return;
    }

    router.refresh();
  }

  if (reservations.length === 0) {
    return <p className="text-stone-600 dark:text-stone-400">Trenutno nema predstojećih rezervacija.</p>;
  }

  const nowDate = new Date(now);
  const sorted = [...reservations].sort((a, b) => new Date(a.starts_at).getTime() - new Date(b.starts_at).getTime());

  // Starting a reservation before its booked time rewrites its start time
  // and can't be undone, so that one transition asks first.
  function requestTransition(reservation: EmployeeReservationRow, newStatus: ReservationStatus) {
    if (newStatus === "ongoing" && new Date(reservation.starts_at).getTime() > nowDate.getTime()) {
      setPendingEarlyStart(reservation);
      return;
    }
    handleTransition(reservation.id, newStatus);
  }

  function confirmEarlyStart() {
    if (!pendingEarlyStart) return;
    const reservationId = pendingEarlyStart.id;
    setPendingEarlyStart(null);
    handleTransition(reservationId, "ongoing");
  }

  return (
    <>
      <ul className="w-full max-w-lg space-y-3">
        {sorted.map((reservation) => (
          <ReservationCard
            key={reservation.id}
            reservation={reservation}
            now={nowDate}
            pending={pendingId === reservation.id}
            error={errors[reservation.id]}
            onTransition={requestTransition}
          />
        ))}
      </ul>

      {pendingEarlyStart && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4 dark:bg-black/60">
          <div
            role="alertdialog"
            aria-modal="true"
            aria-label="Potvrda ranijeg početka"
            className="w-full max-w-sm space-y-4 rounded-lg border border-stone-200 bg-white p-6 shadow-sm dark:border-stone-700 dark:bg-stone-800"
          >
            <p>
              Rezervacija je zakazana za {formatDateTime(pendingEarlyStart.starts_at)}. Ako je sada označite kao u toku,
              njen početak se pomera na trenutno vreme i to se ne može poništiti. Nastaviti?
            </p>
            <div className="flex gap-2">
              <button
                type="button"
                onClick={confirmEarlyStart}
                className="flex-1 rounded-md bg-accent px-3 py-2 text-sm text-accent-foreground hover:opacity-90 active:opacity-80 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
              >
                Nastavi
              </button>
              <button
                type="button"
                onClick={() => setPendingEarlyStart(null)}
                className="flex-1 rounded-md border border-stone-300 px-3 py-2 text-sm hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent dark:border-stone-600 dark:hover:bg-stone-700"
              >
                Otkaži
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
