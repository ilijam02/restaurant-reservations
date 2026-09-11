"use client";

import { useEffect, useMemo, useState, type FormEvent } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { TablePicker, type PickableTable } from "@/components/table-picker";
import { CartSummary, cartTotal, formatPrice, type CartItem } from "@/components/cart-summary";

type Restaurant = {
  id: string;
  name: string;
  capacity: number | null;
  default_stay_minutes: number;
};

type HoursRow = { day_of_week: number; start_minute: number; end_minute: number };
type SectionRow = { id: string; name: string; color_index: number };
type LayoutRow = { id: string; name: string };
type TableRow = {
  id: string;
  name: string;
  seats: number;
  section_id: string | null;
  layout_id: string;
  x: number;
  y: number;
  width: number;
  height: number;
};

const DAY_LABELS: Record<number, string> = {
  0: "Nedelja",
  1: "Ponedeljak",
  2: "Utorak",
  3: "Sreda",
  4: "Četvrtak",
  5: "Petak",
  6: "Subota",
};

// Monday-first display order, matching the owner-side hours calendar.
const DAY_ORDER = [1, 2, 3, 4, 5, 6, 0];

function formatMinutes(min: number) {
  const h = Math.floor(min / 60) % 24;
  const m = min % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

function minDateTimeLocal() {
  const now = new Date();
  now.setMinutes(now.getMinutes() - now.getTimezoneOffset());
  return now.toISOString().slice(0, 16);
}

export function ReservationForm({
  restaurant,
  hours,
  sections,
  layouts,
  tables,
  orderId,
  cartItems,
}: {
  restaurant: Restaurant;
  hours: HoursRow[];
  sections: SectionRow[];
  layouts: LayoutRow[];
  tables: TableRow[];
  orderId: string | null;
  cartItems: CartItem[];
}) {
  const [startsAt, setStartsAt] = useState("");
  const [partySize, setPartySize] = useState("2");
  const [stayMinutes, setStayMinutes] = useState("");
  const [sectionId, setSectionId] = useState("");
  const [selectedTableIds, setSelectedTableIds] = useState<string[]>([]);
  const [occupiedTableIds, setOccupiedTableIds] = useState<Set<string>>(new Set());
  const [sectionRemaining, setSectionRemaining] = useState<Map<string, number>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [confirmation, setConfirmation] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const effectiveStayMinutes = stayMinutes ? Number(stayMinutes) : restaurant.default_stay_minutes;
  const isDurationValid = effectiveStayMinutes >= 30 && effectiveStayMinutes <= 180;
  // Availability (and thus which tables can even be picked) only means
  // something once there's a candidate time range to check it against.
  const canPickTables = startsAt !== "" && isDurationValid;

  // Refetch which tables are already booked whenever the candidate range
  // changes - selection itself is cleared right in the starts-at/duration
  // handlers below, since that's a direct response to the user's edit.
  useEffect(() => {
    if (!canPickTables) return;
    let cancelled = false;
    const supabase = createClient();
    const startDate = new Date(startsAt);
    const startIso = startDate.toISOString();
    const endIso = new Date(startDate.getTime() + effectiveStayMinutes * 60000).toISOString();
    supabase
      .rpc("get_occupied_table_ids", { p_restaurant_id: restaurant.id, p_starts_at: startIso, p_ends_at: endIso })
      .then(({ data }) => {
        if (!cancelled) setOccupiedTableIds(new Set((data ?? []).map((row: { table_id: string }) => row.table_id)));
      });
    return () => {
      cancelled = true;
    };
  }, [canPickTables, startsAt, effectiveStayMinutes, restaurant.id]);

  // Only relevant when there's no active layout - once one exists, a
  // section preference is just picking that section's tables (covered by
  // table occupancy above). Checking whether an active layout *exists*
  // (matching create_reservation()'s own branch condition) rather than
  // whether it has tables - an active-but-empty layout is a real, if rare,
  // owner-side state, and `layouts` here is already fetched pre-filtered
  // to active ones.
  const hasNoLayout = layouts.length === 0;

  // A section preference fills that section first, then spills into others
  // (same as the table-auto-assign path) - so unlike the table borders
  // above, this isn't a live per-table picture but a single "how much room
  // is left in each section" check, used to preview how much would spill.
  useEffect(() => {
    if (!canPickTables || !hasNoLayout || sections.length === 0) return;
    let cancelled = false;
    const supabase = createClient();
    const startDate = new Date(startsAt);
    const startIso = startDate.toISOString();
    const endIso = new Date(startDate.getTime() + effectiveStayMinutes * 60000).toISOString();
    supabase
      .rpc("get_section_remaining_capacity", { p_restaurant_id: restaurant.id, p_starts_at: startIso, p_ends_at: endIso })
      .then(({ data }) => {
        if (!cancelled) {
          setSectionRemaining(
            new Map((data ?? []).map((row: { section_id: string; remaining: number }) => [row.section_id, row.remaining])),
          );
        }
      });
    return () => {
      cancelled = true;
    };
  }, [canPickTables, hasNoLayout, sections.length, startsAt, effectiveStayMinutes, restaurant.id]);

  const hoursByDay = useMemo(() => {
    const map = new Map<number, HoursRow[]>();
    for (const h of hours) {
      const list = map.get(h.day_of_week) ?? [];
      list.push(h);
      map.set(h.day_of_week, list);
    }
    return map;
  }, [hours]);

  const selectedSeats = useMemo(
    () => tables.filter((t) => selectedTableIds.includes(t.id)).reduce((sum, t) => sum + t.seats, 0),
    [tables, selectedTableIds],
  );
  // Selecting tables fixes the party size to their combined seating -
  // override the free-typed value rather than syncing it via an effect.
  const effectivePartySize = selectedTableIds.length > 0 ? String(selectedSeats) : partySize;

  // How many guests would spill into another section if the chosen
  // preference doesn't have room - create_reservation() fills the
  // preferred section first, then spills the remainder into other
  // sections rather than rejecting the booking outright, so this is
  // informational, not a "this booking will fail" warning. It only checks
  // the preferred section's own room though, not whether the rest of the
  // restaurant can actually absorb the spillover - the message is worded
  // to hedge on that ("might", not "will") since submission can still fail
  // if there truly isn't enough room anywhere.
  const sectionShortfall = useMemo(() => {
    if (!canPickTables || !sectionId) return 0;
    const remaining = sectionRemaining.get(sectionId);
    if (remaining === undefined) return 0;
    const party = Number(effectivePartySize) || 0;
    return Math.max(0, party - remaining);
  }, [canPickTables, sectionId, sectionRemaining, effectivePartySize]);

  const sectionColorBySectionId = useMemo(() => new Map(sections.map((s) => [s.id, s.color_index])), [sections]);
  const pickableTables: PickableTable[] = useMemo(
    () =>
      tables.map((t) => ({
        id: t.id,
        name: t.name,
        seats: t.seats,
        sectionId: t.section_id,
        sectionColorIndex: t.section_id ? (sectionColorBySectionId.get(t.section_id) ?? null) : null,
        layoutId: t.layout_id,
        x: t.x,
        y: t.y,
        width: t.width,
        height: t.height,
      })),
    [tables, sectionColorBySectionId],
  );

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setConfirmation(null);
    setLoading(true);

    const supabase = createClient();
    const hasTables = selectedTableIds.length > 0;
    const { data, error: rpcError } = await supabase.rpc("create_reservation", {
      p_restaurant_id: restaurant.id,
      p_party_size: Number(effectivePartySize),
      p_starts_at: new Date(startsAt).toISOString(),
      p_stay_minutes: stayMinutes ? Number(stayMinutes) : null,
      p_section_id: hasTables ? null : sectionId || null,
      p_table_ids: hasTables ? selectedTableIds : null,
      p_order_id: cartItems.length > 0 ? orderId : null,
    });

    if (rpcError || !data) {
      setLoading(false);
      setError(rpcError?.message ?? "Rezervacija nije uspela. Pokušajte ponovo.");
      return;
    }

    // Auto-assignment means the customer doesn't necessarily know what they
    // got - look up what was actually assigned so the confirmation isn't
    // silent about it. Tables can span more than one layout (e.g. a spillover
    // out of a preferred section's layout), so group by layout name rather
    // than listing them flat.
    let assignedText = "";
    const { data: assignedTables } = await supabase
      .from("reservation_tables")
      .select("tables(name, layouts(name))")
      .eq("reservation_id", data.id);
    if (assignedTables && assignedTables.length > 0) {
      const groups = new Map<string, string[]>();
      for (const row of assignedTables) {
        const table = row.tables as unknown as { name: string; layouts: { name: string } | null };
        const layoutName = table.layouts?.name ?? "Raspored";
        const names = groups.get(layoutName) ?? [];
        names.push(table.name);
        groups.set(layoutName, names);
      }
      assignedText = ` ${[...groups.entries()].map(([layoutName, names]) => `${layoutName}: ${names.join(", ")}`).join(", ")}.`;
    } else {
      const { data: assignedSections } = await supabase
        .from("reservation_sections")
        .select("sections(name)")
        .eq("reservation_id", data.id);
      if (assignedSections && assignedSections.length > 0) {
        const names = assignedSections.map((row) => (row.sections as unknown as { name: string }).name);
        assignedText = ` Sekcija: ${names.join(", ")}.`;
      }
    }

    setLoading(false);
    const confirmedAt = new Date(data.starts_at);
    const orderText = cartItems.length > 0 ? ` Porudžbina u iznosu od ${formatPrice(cartTotal(cartItems))} je plaćena.` : "";
    setConfirmation(
      `Potvrđeno: rezervacija za ${confirmedAt.toLocaleDateString("sr-RS")} u ${confirmedAt.toLocaleTimeString("sr-RS", { hour: "2-digit", minute: "2-digit" })}.${assignedText}${orderText}`,
    );
    setStartsAt("");
    setStayMinutes("");
    setSectionId("");
    setSelectedTableIds([]);
  }

  return (
    <div className="w-full max-w-3xl space-y-6">
      <div className="rounded-lg border border-stone-200 bg-white p-6 shadow-sm dark:border-stone-700 dark:bg-stone-800">
        <h2 className="mb-2 text-sm font-medium">Radno vreme</h2>
        {hours.length === 0 ? (
          <p className="text-sm text-stone-600 dark:text-stone-400">Radno vreme nije podešeno.</p>
        ) : (
          <ul className="space-y-1 text-sm text-stone-700 dark:text-stone-300">
            {DAY_ORDER.map((day) => {
              const blocks = (hoursByDay.get(day) ?? []).slice().sort((a, b) => a.start_minute - b.start_minute);
              return (
                <li key={day} className="flex justify-between gap-4">
                  <span>{DAY_LABELS[day]}</span>
                  <span className="text-stone-500 dark:text-stone-400">
                    {blocks.length === 0
                      ? "Zatvoreno"
                      : blocks.map((b) => `${formatMinutes(b.start_minute)}–${formatMinutes(b.end_minute)}`).join(", ")}
                  </span>
                </li>
              );
            })}
          </ul>
        )}
      </div>

      <form
        onSubmit={handleSubmit}
        className="space-y-4 rounded-lg border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-700 dark:bg-stone-800"
      >
        <h2 className="text-xl font-semibold">Rezerviši</h2>

        <div className="space-y-1">
          <label htmlFor="starts-at" className="block text-sm font-medium">
            Datum i vreme
          </label>
          <input
            id="starts-at"
            type="datetime-local"
            required
            min={minDateTimeLocal()}
            value={startsAt}
            onChange={(event) => {
              setStartsAt(event.target.value);
              setSelectedTableIds([]);
            }}
            className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100"
          />
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div className="space-y-1">
            <label htmlFor="party-size" className="block text-sm font-medium">
              Broj gostiju
            </label>
            <input
              id="party-size"
              type="number"
              min={1}
              required
              readOnly={selectedTableIds.length > 0}
              value={effectivePartySize}
              onChange={(event) => setPartySize(event.target.value)}
              className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent read-only:cursor-not-allowed read-only:bg-stone-100 dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:read-only:bg-stone-900"
            />
            {selectedTableIds.length > 0 && (
              <p className="text-xs text-stone-500 dark:text-stone-400">Određeno izabranim stolovima.</p>
            )}
          </div>

          <div className="space-y-1">
            <label htmlFor="stay-minutes" className="block text-sm font-medium">
              Trajanje (min)
            </label>
            <input
              id="stay-minutes"
              type="number"
              placeholder={restaurant.default_stay_minutes.toString()}
              value={stayMinutes}
              onChange={(event) => {
                setStayMinutes(event.target.value);
                setSelectedTableIds([]);
              }}
              className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
            />
            <p className="text-xs text-stone-500 dark:text-stone-400">Između 30 i 180 minuta.</p>
          </div>
        </div>

        {/* Only offered when there's no active layout - once one exists, a
            section preference is expressed by picking that section's
            tables directly in the picker below. */}
        {sections.length > 0 && hasNoLayout && (
          <div className="space-y-1">
            <label htmlFor="section" className="block text-sm font-medium">
              Sekcija (opciono)
            </label>
            <select
              id="section"
              value={sectionId}
              onChange={(event) => setSectionId(event.target.value)}
              className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100"
            >
              <option value="">Bez preference</option>
              {sections.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
            {sectionShortfall > 0 && (
              <p role="status" className="text-xs text-warning">
                {`Upozorenje: ova sekcija trenutno nema dovoljno slobodnih mesta za celu grupu - ${sectionShortfall} ${sectionShortfall === 1 ? "gost" : "gostiju"} moglo bi biti smešteno u drugu sekciju, ako ima mesta.`}
              </p>
            )}
          </div>
        )}

        {pickableTables.length > 0 && (
          <div className="space-y-1">
            <span className="block text-sm font-medium">Sto (opciono)</span>
            <TablePicker
              tables={pickableTables}
              layouts={layouts}
              sections={sections.map((s) => ({ id: s.id, name: s.name, colorIndex: s.color_index }))}
              value={selectedTableIds}
              onChange={setSelectedTableIds}
              enabled={canPickTables}
              occupiedTableIds={occupiedTableIds}
            />
          </div>
        )}

        <div className="space-y-2 border-t border-stone-200 pt-4 dark:border-stone-700">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-medium">Porudžbina</h3>
            <Link
              href={`/customer/restaurants/${restaurant.id}`}
              className="text-sm text-orange-700 hover:underline dark:text-accent"
            >
              ← Izmeni porudžbinu
            </Link>
          </div>
          <CartSummary items={cartItems} mode="readonly" />
        </div>

        {cartItems.length > 0 && (
          <div className="space-y-2 rounded-md border border-stone-200 bg-stone-50 p-4 dark:border-stone-700 dark:bg-stone-900/40">
            <h3 className="text-sm font-medium">Plaćanje karticom</h3>
            <p className="text-sm text-stone-600 dark:text-stone-400">
              Integracija plaćanja uskoro dolazi - trenutno se samo simulira.
            </p>
          </div>
        )}

        {error && (
          <p role="alert" className="text-sm text-red-600 dark:text-red-400">
            {error}
          </p>
        )}

        {confirmation && (
          <p role="status" className="text-sm text-success">
            {confirmation}
          </p>
        )}

        <button
          type="submit"
          disabled={loading}
          className="w-full rounded-md bg-accent px-3 py-2 text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
        >
          {loading ? "Obrada..." : cartItems.length > 0 ? "Plati i potvrdi rezervaciju" : "Rezerviši"}
        </button>
      </form>
    </div>
  );
}
