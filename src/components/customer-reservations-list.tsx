"use client";

import { useState } from "react";
import { CartSummary, type CartItem } from "@/components/cart-summary";

type ReservationStatus = "confirmed" | "preparing_order" | "order_prepared" | "ongoing" | "cancelled" | "completed" | "no_show";

// Mirrors is_active_reservation_status() in the DB (see
// 20260917140000_reservation_status_lifecycle.sql) - a reservation
// mid-service is still "current" from the customer's point of view too.
const ACTIVE_STATUSES: ReservationStatus[] = ["confirmed", "preparing_order", "order_prepared", "ongoing"];

export type ReservationRow = {
  id: string;
  party_size: number;
  starts_at: string;
  ends_at: string;
  status: ReservationStatus;
  restaurants: { name: string } | null;
  reservation_tables: { tables: { name: string } | null }[];
  reservation_sections: { party_size: number; sections: { name: string } | null }[];
  orders: { status: string; items: CartItem[] }[];
};

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
  preparing_order: "bg-warning/10 text-warning",
  order_prepared: "bg-warning/10 text-warning",
  ongoing: "bg-success/10 text-success",
  completed: "bg-success/10 text-success",
  cancelled: "bg-danger/10 text-danger",
  no_show: "bg-danger/10 text-danger",
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

function ReservationCard({ reservation }: { reservation: ReservationRow }) {
  const [expanded, setExpanded] = useState(false);
  const order = reservation.orders[0];
  const hasOrder = !!order && order.items.length > 0;
  const seating = seatingLabel(reservation);

  return (
    <li className="rounded-lg border border-stone-200 bg-white p-4 dark:border-stone-700 dark:bg-stone-800">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium">{reservation.restaurants?.name ?? "Restoran"}</p>
          <p className="text-sm text-stone-600 dark:text-stone-400">{formatDateTime(reservation.starts_at)}</p>
          <p className="text-sm text-stone-600 dark:text-stone-400">{guestCountLabel(reservation.party_size)}</p>
          {seating && <p className="text-sm text-stone-600 dark:text-stone-400">{seating}</p>}
        </div>
        <span className={`shrink-0 rounded-full px-3 py-1 text-sm font-medium ${STATUS_CLASSES[reservation.status]}`}>
          {STATUS_LABELS[reservation.status]}
        </span>
      </div>

      {hasOrder && (
        <>
          <button
            type="button"
            aria-expanded={expanded}
            onClick={() => setExpanded((value) => !value)}
            className="mt-3 rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent dark:border-stone-600 dark:hover:bg-stone-700"
          >
            {expanded ? "Sakrij porudžbinu" : "Prikaži porudžbinu"}
          </button>

          {expanded && (
            <div className="mt-3 border-t border-stone-200 pt-3 dark:border-stone-700">
              <CartSummary items={order.items} mode="readonly" />
            </div>
          )}
        </>
      )}
    </li>
  );
}

// `now` is computed once by the server-component caller and passed down as a
// prop (rather than each client calling `new Date()` itself) so the initial
// server render and the client hydration pass classify reservations
// identically - a `new Date()` call here would risk a reservation flipping
// current/past between the two if its ends_at fell in between.
export function CustomerReservationsList({ reservations, now }: { reservations: ReservationRow[]; now: string }) {
  if (reservations.length === 0) {
    return <p className="text-stone-600 dark:text-stone-400">Trenutno nemate rezervacija.</p>;
  }

  const nowDate = new Date(now);
  const current = reservations
    .filter((r) => isCurrent(r, nowDate))
    .sort((a, b) => new Date(a.starts_at).getTime() - new Date(b.starts_at).getTime());
  const past = reservations
    .filter((r) => !isCurrent(r, nowDate))
    .sort((a, b) => new Date(b.starts_at).getTime() - new Date(a.starts_at).getTime());

  return (
    <div className="w-full max-w-lg space-y-8">
      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Trenutne rezervacije</h2>
        {current.length === 0 ? (
          <p className="text-sm text-stone-600 dark:text-stone-400">Nemate predstojećih rezervacija.</p>
        ) : (
          <ul className="space-y-3">
            {current.map((reservation) => (
              <ReservationCard key={reservation.id} reservation={reservation} />
            ))}
          </ul>
        )}
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Prošle rezervacije</h2>
        {past.length === 0 ? (
          <p className="text-sm text-stone-600 dark:text-stone-400">Nemate prošlih rezervacija.</p>
        ) : (
          <ul className="space-y-3">
            {past.map((reservation) => (
              <ReservationCard key={reservation.id} reservation={reservation} />
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
