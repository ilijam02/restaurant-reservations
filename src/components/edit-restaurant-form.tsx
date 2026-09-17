"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { RestaurantHoursCalendar, type HourBlock } from "@/components/restaurant-hours-calendar";
import { SectionsEditor, type DraftSection } from "@/components/sections-editor";
import { LayoutsEditor, type DraftLayout } from "@/components/layouts-editor";
import { TableLayoutEditor, type DraftTable } from "@/components/table-layout-editor";
import { computeCapacitySums } from "@/lib/capacity-cascade";

type Restaurant = {
  id: string;
  name: string;
  capacity: number | null;
  default_stay_minutes: number;
};

type HoursRow = {
  day_of_week: number;
  start_minute: number;
  end_minute: number;
};

type SectionRow = { id: string; name: string; capacity: number; color_index: number };
type LayoutRow = { id: string; name: string; is_active: boolean };
type TableRow = {
  id: string;
  layout_id: string;
  name: string;
  seats: number;
  section_id: string | null;
  x: number;
  y: number;
  width: number;
  height: number;
};

const DUPLICATE_SECTION_NAME_ERROR = "Sekcija sa ovim nazivom već postoji.";
const DUPLICATE_LAYOUT_NAME_ERROR = "Raspored sa ovim nazivom već postoji.";
const SECTIONS_SAVE_ERROR = "Čuvanje sekcija nije uspelo. Pokušajte ponovo.";
const SECTION_HAS_TABLES_ERROR =
  "Ne možete obrisati sekciju dok joj je dodeljen sto u aktivnom rasporedu - prvo promenite ili uklonite te stolove.";
const LAYOUT_MISSING_SECTION_ERROR = "Svi stolovi u aktivnim rasporedima moraju imati sekciju.";
const DEFAULT_STAY_MINUTES_RANGE_ERROR = "Trajanje rezervacije mora biti između 30 i 180 minuta.";
const SAVE_ERROR = "Čuvanje izmena nije uspelo. Pokušajte ponovo.";

// A raised `P0001` (plain `raise exception`) is one of this project's own
// deliberate business-rule messages (see e.g. prevent_table_delete_with_active_reservation()
// in 20260913140000_protect_capacity_from_active_reservations.sql) - already
// Serbian and specific, so show it verbatim instead of the generic fallback.
function raisedMessageOr(error: { code?: string; message: string } | null, fallback: string) {
  return error?.code === "P0001" ? error.message : fallback;
}

// Matches customer-reservations-list.tsx's own formatDateTime - duplicated
// rather than imported, since that component lives under the customer role
// and this form is owner-facing (see CLAUDE.md's role-folder separation
// convention); there's no shared date util yet either way.
function formatReservationDateTime(iso: string) {
  const date = new Date(iso);
  const day = date.toLocaleDateString("sr-RS", { timeZone: "Europe/Belgrade" });
  const time = date.toLocaleTimeString("sr-RS", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Belgrade" });
  return `${day} ${time}`;
}

function guestCountLabel(partySize: number) {
  return `${partySize} ${partySize === 1 ? "gost" : "gostiju"}`;
}

type ActiveReservationBlocker = { starts_at: string; party_size: number };
type BlockedTableRow = ActiveReservationBlocker & { table_name: string; layout_name: string };

function describeBlockedTable(r: BlockedTableRow) {
  return `"${r.table_name}" (${formatReservationDateTime(r.starts_at)}, ${guestCountLabel(r.party_size)})`;
}

// Table names are only unique per layout, not per restaurant (two layouts
// can each have their own "Sto 1") - once a save spans more than one
// layout, a flat list would be ambiguous about which layout a given table
// belongs to, so group by layout in that case. A single layout keeps the
// simpler flat list, since there's nothing to disambiguate.
function describeBlockedTables(rows: BlockedTableRow[]) {
  const layoutNames = Array.from(new Set(rows.map((r) => r.layout_name)));

  const list =
    layoutNames.length <= 1
      ? rows.map(describeBlockedTable).join(", ")
      : layoutNames
          .map((layoutName) => `${layoutName}: ${rows.filter((r) => r.layout_name === layoutName).map(describeBlockedTable).join(", ")}`)
          .join("; ");

  return `Sledeći stolovi imaju aktivnu rezervaciju i ne mogu biti obrisani: ${list}.`;
}

function describeBlockedSections(rows: (ActiveReservationBlocker & { section_name: string })[]) {
  const list = rows
    .map((r) => `"${r.section_name}" (${formatReservationDateTime(r.starts_at)}, ${guestCountLabel(r.party_size)})`)
    .join(", ");
  return `Sledeće sekcije imaju aktivnu rezervaciju i ne mogu biti obrisane: ${list}.`;
}

function describeSectionsBelowCapacity(rows: { section_name: string; peak_capacity: number }[]) {
  const list = rows.map((r) => `"${r.section_name}" (potrebno najmanje ${r.peak_capacity})`).join(", ");
  return `Kapacitet sledećih sekcija ne može biti manji od broja gostiju sa već potvrđenom rezervacijom: ${list}.`;
}

function initialBlocks(hours: HoursRow[]): HourBlock[] {
  return hours.map((h) => ({
    id: crypto.randomUUID(),
    dayOfWeek: h.day_of_week,
    start: h.start_minute,
    end: h.end_minute,
  }));
}

// An existing section's key is its own id (deterministic, matches server
// and client render alike, and is exactly what tables' sectionKey values
// are seeded from below) - a random key here would both mismatch on
// hydration and never match any table's real section_id.
function initialDraftSections(sections: SectionRow[]): DraftSection[] {
  return sections.map((s) => ({
    key: s.id,
    id: s.id,
    name: s.name,
    capacity: s.capacity.toString(),
    colorIndex: s.color_index,
  }));
}

function initialDraftLayouts(layouts: LayoutRow[]): DraftLayout[] {
  return layouts.map((l) => ({ key: l.id, id: l.id, name: l.name, isActive: l.is_active }));
}

// Every layout gets an entry (even an empty one) so opening a table-less
// layout on the canvas doesn't need special-casing anywhere.
function initialTablesByLayoutKey(layouts: LayoutRow[], tables: TableRow[]): Record<string, DraftTable[]> {
  const result: Record<string, DraftTable[]> = {};
  for (const l of layouts) result[l.id] = [];
  for (const t of tables) {
    const bucket = result[t.layout_id] ?? (result[t.layout_id] = []);
    bucket.push({
      key: t.id,
      id: t.id,
      name: t.name,
      seats: t.seats.toString(),
      sectionKey: t.section_id,
      x: t.x,
      y: t.y,
      width: t.width,
      height: t.height,
    });
  }
  return result;
}

function sumDraftCapacity(sections: DraftSection[]) {
  return sections.reduce((sum, s) => sum + (Number(s.capacity) || 0), 0);
}

export function EditRestaurantForm({
  restaurant,
  hours,
  sections,
  layouts,
  tables,
}: {
  restaurant: Restaurant;
  hours: HoursRow[];
  sections: SectionRow[];
  layouts: LayoutRow[];
  tables: TableRow[];
}) {
  const router = useRouter();
  const [name, setName] = useState(restaurant.name);
  const [capacity, setCapacity] = useState(restaurant.capacity?.toString() ?? "");
  const [defaultStayMinutes, setDefaultStayMinutes] = useState(
    restaurant.default_stay_minutes.toString(),
  );
  const [blocks, setBlocks] = useState<HourBlock[]>(() => initialBlocks(hours));
  const [draftSections, setDraftSections] = useState<DraftSection[]>(() => initialDraftSections(sections));
  const [draftLayouts, setDraftLayouts] = useState<DraftLayout[]>(() => initialDraftLayouts(layouts));
  // Which layout's canvas is open for editing - independent of which
  // layout(s) are active. Defaults to the first active one if any, else
  // just the first layout, so opening the page shows something useful.
  const [editingLayoutKey, setEditingLayoutKey] = useState<string | null>(() => {
    const firstActive = layouts.find((l) => l.is_active);
    return (firstActive ?? layouts[0])?.id ?? null;
  });
  const [tablesByLayoutKey, setTablesByLayoutKey] = useState<Record<string, DraftTable[]>>(() =>
    initialTablesByLayoutKey(layouts, tables),
  );
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  // Capacity (both here and per-section) is derived live from the union of
  // every *active* layout's draft tables - always in sync with whatever's
  // been edited locally, no save/reload needed to see it. The layout open
  // on the canvas (editingLayoutKey) is a separate concept - it doesn't
  // have to be active to be edited.
  const activeLayoutKeys = draftLayouts.filter((l) => l.isActive).map((l) => l.key);
  const hasActiveLayouts = activeLayoutKeys.length > 0;
  const hasSections = draftSections.length > 0;
  const activeTables = activeLayoutKeys.flatMap((key) => tablesByLayoutKey[key] ?? []);
  const editingLayoutTables = editingLayoutKey ? (tablesByLayoutKey[editingLayoutKey] ?? []) : [];
  const liveCapacity = computeCapacitySums(
    activeTables.map((t) => ({ sectionId: t.sectionKey, seats: Number(t.seats) || 0 })),
  );
  const derivedSectionsCapacity = sumDraftCapacity(draftSections);

  function handleSectionsChange(next: DraftSection[]) {
    // Removing the last section unfreezes the capacity field back to
    // manual editability - it shows whatever was last stored in the
    // database (untouched the whole time sections existed, since that
    // column is only ever written to in "no sections, no active layout"
    // mode), not a value seeded from the sections that just got deleted.

    // A removed section's key can't keep dangling as a table's sectionKey
    // in ANY layout - unassign it everywhere, live, the moment it's gone.
    const remainingKeys = new Set(next.map((s) => s.key));
    const removedKeys = draftSections.filter((s) => !remainingKeys.has(s.key)).map((s) => s.key);
    if (removedKeys.length > 0) {
      setTablesByLayoutKey((prev) => {
        const updated: typeof prev = {};
        for (const [layoutKey, layoutTables] of Object.entries(prev)) {
          updated[layoutKey] = layoutTables.map((t) =>
            t.sectionKey && removedKeys.includes(t.sectionKey) ? { ...t, sectionKey: null } : t,
          );
        }
        return updated;
      });
    }

    setDraftSections(next);
  }

  function handleLayoutsChange(next: DraftLayout[]) {
    const remainingKeys = new Set(next.map((l) => l.key));
    setTablesByLayoutKey((prev) => {
      const updated = { ...prev };
      for (const key of Object.keys(updated)) {
        if (!remainingKeys.has(key)) delete updated[key];
      }
      return updated;
    });
    setDraftLayouts(next);
  }

  function handleEditingLayoutTablesChange(next: DraftTable[]) {
    if (!editingLayoutKey) return;
    setTablesByLayoutKey((prev) => ({ ...prev, [editingLayoutKey]: next }));
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setLoading(true);

    const supabase = createClient();

    const removedSections = sections.filter((original) => !draftSections.some((d) => d.id === original.id));
    const removedSectionIds = removedSections.map((s) => s.id);

    // A section still holding tables in an *active* layout can't be
    // deleted while other sections would remain afterward - those tables
    // would be left without a section, which is only ever valid when the
    // restaurant has none at all.
    if (removedSectionIds.length && draftSections.length > 0) {
      const blocked = removedSectionIds.some((id) => activeTables.some((t) => t.sectionKey === id));
      if (blocked) {
        setLoading(false);
        setError(SECTION_HAS_TABLES_ERROR);
        return;
      }
    }

    if (hasActiveLayouts && hasSections && activeTables.some((t) => t.sectionKey === null)) {
      setLoading(false);
      setError(LAYOUT_MISSING_SECTION_ERROR);
      return;
    }

    // Deletion pre-check: gather every table this save would actually
    // delete - either directly, or via cascade from a whole layout being
    // removed - and every section being removed, then ask the DB which of
    // them still has an active reservation *before* attempting any delete.
    // Without this, the .delete() calls further down would still be
    // correctly rejected by the DB triggers, but only one table/section at a
    // time (a trigger aborts the whole statement on the first row it finds),
    // forcing the owner to retry repeatedly to discover the rest.
    const removedLayoutIds = layouts.filter((orig) => !draftLayouts.some((d) => d.id === orig.id)).map((l) => l.id);
    const tablesOnRemovedLayoutIds = tables.filter((t) => removedLayoutIds.includes(t.layout_id)).map((t) => t.id);

    const originalTablesByLayoutId = new Map<string, TableRow[]>();
    for (const t of tables) {
      const bucket = originalTablesByLayoutId.get(t.layout_id) ?? [];
      bucket.push(t);
      originalTablesByLayoutId.set(t.layout_id, bucket);
    }
    // Only surviving *existing* layouts can have original tables to diff
    // against - a brand new layout (id === null) can't have removed any
    // table that was ever actually saved.
    const removedTableIdsFromSurvivingLayouts = draftLayouts.flatMap((layout) => {
      if (!layout.id) return [];
      const draftTablesForLayout = tablesByLayoutKey[layout.key] ?? [];
      const originalTablesForLayout = originalTablesByLayoutId.get(layout.id) ?? [];
      return originalTablesForLayout
        .filter((original) => !draftTablesForLayout.some((d) => d.id === original.id))
        .map((t) => t.id);
    });
    const allRemovedTableIds = [...tablesOnRemovedLayoutIds, ...removedTableIdsFromSurvivingLayouts];

    if (allRemovedTableIds.length) {
      const { data: blockedTables } = await supabase.rpc("tables_with_active_reservations", {
        p_table_ids: allRemovedTableIds,
      });
      if (blockedTables && blockedTables.length > 0) {
        setLoading(false);
        setError(describeBlockedTables(blockedTables));
        return;
      }
    }

    if (removedSectionIds.length) {
      const { data: blockedSections } = await supabase.rpc("sections_with_active_reservations", {
        p_section_ids: removedSectionIds,
      });
      if (blockedSections && blockedSections.length > 0) {
        setLoading(false);
        setError(describeBlockedSections(blockedSections));
        return;
      }
    }

    // originalSectionById/toUpdateSections are needed both by the capacity
    // pre-check (deliberately run much later, right before the rename dance
    // it protects - see that comment) and by the actual section mutations
    // further down.
    const originalSectionById = new Map(sections.map((s) => [s.id, s]));
    const toUpdateSections = draftSections.filter((s): s is DraftSection & { id: string } => {
      if (s.id === null) return false;
      const original = originalSectionById.get(s.id);
      if (!original) return true;
      return original.name !== s.name || (!hasActiveLayouts && original.capacity !== Number(s.capacity));
    });

    // Layouts: new ones first (real ids known before anything references
    // them, is_active included directly in the insert), then removed ones
    // (cascades their tables at the DB level).
    const toInsertLayouts = draftLayouts.filter((l) => l.id === null);
    const { data: insertedLayouts, error: insertLayoutsError } = toInsertLayouts.length
      ? await supabase
          .from("layouts")
          .insert(toInsertLayouts.map((l) => ({ restaurant_id: restaurant.id, name: l.name, is_active: l.isActive })))
          .select("id")
      : { data: [], error: null };

    if (insertLayoutsError) {
      setLoading(false);
      setError(insertLayoutsError.code === "23505" ? DUPLICATE_LAYOUT_NAME_ERROR : SAVE_ERROR);
      return;
    }

    const keyToRealLayoutId = new Map<string, string>();
    toInsertLayouts.forEach((l, index) => {
      const inserted = insertedLayouts?.[index];
      if (inserted) keyToRealLayoutId.set(l.key, inserted.id);
    });
    for (const l of draftLayouts) if (l.id) keyToRealLayoutId.set(l.key, l.id);

    const { error: deleteLayoutsError } = removedLayoutIds.length
      ? await supabase.from("layouts").delete().in("id", removedLayoutIds)
      : { error: null };

    if (deleteLayoutsError) {
      setLoading(false);
      setError(raisedMessageOr(deleteLayoutsError, SAVE_ERROR));
      return;
    }

    // Existing layouts whose active flag actually changed.
    const originalLayoutById = new Map(layouts.map((l) => [l.id, l]));
    const toUpdateLayoutActive = draftLayouts.filter((l): l is DraftLayout & { id: string } => {
      if (!l.id) return false;
      const original = originalLayoutById.get(l.id);
      return original ? original.is_active !== l.isActive : false;
    });
    const updateLayoutActiveResults = await Promise.all(
      toUpdateLayoutActive.map((l) => supabase.from("layouts").update({ is_active: l.isActive }).eq("id", l.id)),
    );
    const updateLayoutActiveError = updateLayoutActiveResults.map((r) => r.error).find((e) => e !== null) ?? null;

    if (updateLayoutActiveError) {
      setLoading(false);
      setError(SAVE_ERROR);
      return;
    }

    const { error: restaurantError } = await supabase
      .from("restaurants")
      .update({ name, default_stay_minutes: Number(defaultStayMinutes) })
      .eq("id", restaurant.id);

    if (restaurantError) {
      setLoading(false);
      setError(restaurantError.code === "23514" ? DEFAULT_STAY_MINUTES_RANGE_ERROR : SAVE_ERROR);
      return;
    }

    const { error: deleteHoursError } = await supabase
      .from("restaurant_hours")
      .delete()
      .eq("restaurant_id", restaurant.id);

    const { error: insertHoursError } = deleteHoursError
      ? { error: deleteHoursError }
      : blocks.length === 0
        ? { error: null }
        : await supabase.from("restaurant_hours").insert(
            blocks.map((b) => ({
              restaurant_id: restaurant.id,
              day_of_week: b.dayOfWeek,
              start_minute: b.start,
              end_minute: b.end,
            })),
          );

    if (insertHoursError) {
      setLoading(false);
      setError("Čuvanje radnog vremena nije uspelo. Pokušajte ponovo.");
      return;
    }

    const { error: deleteSectionsError } = removedSectionIds.length
      ? await supabase.from("sections").delete().in("id", removedSectionIds)
      : { error: null };

    if (deleteSectionsError) {
      setLoading(false);
      setError(raisedMessageOr(deleteSectionsError, SECTIONS_SAVE_ERROR));
      return;
    }

    const toInsertSections = draftSections
      .filter((s) => s.id === null)
      .map((s) => ({
        restaurant_id: restaurant.id,
        name: s.name,
        capacity: hasActiveLayouts ? 0 : Number(s.capacity),
        color_index: s.colorIndex,
      }));

    // Section capacity pre-check: deliberately run here, immediately before
    // the rename-then-update dance it protects, rather than up at the top
    // with the other early pre-checks - the actual capacity+name update
    // below is preceded by a rename-to-temp-placeholder step (for rows that
    // need it) committed as its own statement with nothing to roll it back
    // if the real update then fails, so a section whose capacity decrease
    // gets rejected would otherwise be left stuck on that temp name. Placing
    // this check right next to that risk, rather than several unrelated
    // awaited calls (layouts, hours, restaurant name) earlier, minimizes -
    // without fully eliminating - the window in which a new reservation
    // could land between "checked safe" and "written," which would let the
    // real update fail anyway despite passing here. Reports every offending
    // section in one message either way.
    if (!hasActiveLayouts) {
      const sectionsWithCapacityChange = toUpdateSections.filter(
        (s) => originalSectionById.get(s.id)?.capacity !== Number(s.capacity),
      );
      if (sectionsWithCapacityChange.length) {
        const { data: sectionPeaks } = await supabase.rpc("sections_peak_reserved_capacity", {
          p_section_ids: sectionsWithCapacityChange.map((s) => s.id),
        });
        const peakBySectionId = new Map(
          ((sectionPeaks ?? []) as { section_id: string; section_name: string; peak_capacity: number }[]).map((row) => [
            row.section_id,
            row,
          ]),
        );
        const belowCapacity = sectionsWithCapacityChange
          .map((s) => peakBySectionId.get(s.id))
          .filter((row): row is { section_id: string; section_name: string; peak_capacity: number } => !!row)
          .filter((row) => {
            const draft = sectionsWithCapacityChange.find((s) => s.id === row.section_id);
            return !!draft && Number(draft.capacity) < row.peak_capacity;
          });

        if (belowCapacity.length > 0) {
          setLoading(false);
          setError(describeSectionsBelowCapacity(belowCapacity));
          return;
        }
      }
    }

    // Renaming sections can swap names between two existing rows, which the
    // unique (restaurant_id, name) constraint would reject if applied
    // directly - stage every row whose name is actually changing through a
    // guaranteed-unique temp name first so no two writes here can
    // transiently collide. Only rows with an actual name change go through
    // this (not every row in toUpdateSections, which also includes
    // capacity-only changes) - narrows the window between this statement and
    // the real update below (see the capacity pre-check's own comment on the
    // race it can't fully close) to just the cases that genuinely need it.
    const sectionsNeedingRename = toUpdateSections.filter((s) => originalSectionById.get(s.id)?.name !== s.name);
    const stageRenameResults = sectionsNeedingRename.length
      ? await Promise.all(
          sectionsNeedingRename.map((s) => supabase.from("sections").update({ name: `__tmp_${s.id}` }).eq("id", s.id)),
        )
      : [];
    const stageRenameError = stageRenameResults.map((r) => r.error).find((e) => e !== null) ?? null;

    if (stageRenameError) {
      setLoading(false);
      setError(SECTIONS_SAVE_ERROR);
      return;
    }

    const { data: insertedSections, error: insertSectionsError } = toInsertSections.length
      ? await supabase.from("sections").insert(toInsertSections).select("id")
      : { data: [], error: null };

    const updateSectionResults = insertSectionsError
      ? []
      : await Promise.all(
          toUpdateSections.map((s) =>
            supabase
              .from("sections")
              .update(hasActiveLayouts ? { name: s.name } : { name: s.name, capacity: Number(s.capacity) })
              .eq("id", s.id),
          ),
        );
    const sectionsError = insertSectionsError ?? updateSectionResults.map((r) => r.error).find((e) => e !== null) ?? null;

    if (sectionsError) {
      setLoading(false);
      setError(
        sectionsError.code === "23505" ? DUPLICATE_SECTION_NAME_ERROR : raisedMessageOr(sectionsError, SECTIONS_SAVE_ERROR),
      );
      return;
    }

    const keyToRealSectionId = new Map<string, string>();
    const newSectionDrafts = draftSections.filter((s) => s.id === null);
    newSectionDrafts.forEach((s, index) => {
      const inserted = insertedSections?.[index];
      if (inserted) keyToRealSectionId.set(s.key, inserted.id);
    });
    for (const s of draftSections) if (s.id) keyToRealSectionId.set(s.key, s.id);

    // Tables: reconcile every surviving layout's draft against what it had
    // originally, not just the one open on the canvas - the owner may have
    // edited several layouts in this same session before saving.
    // (originalTablesByLayoutId was already built above, for the pre-check.)
    for (const layout of draftLayouts) {
      const realLayoutId = keyToRealLayoutId.get(layout.key);
      if (!realLayoutId) continue;

      const draftTablesForLayout = tablesByLayoutKey[layout.key] ?? [];
      const originalTablesForLayout = originalTablesByLayoutId.get(realLayoutId) ?? [];

      const removedTableIds = originalTablesForLayout
        .filter((original) => !draftTablesForLayout.some((d) => d.id === original.id))
        .map((t) => t.id);

      const { error: deleteTablesError } = removedTableIds.length
        ? await supabase.from("tables").delete().in("id", removedTableIds)
        : { error: null };

      if (deleteTablesError) {
        setLoading(false);
        setError(raisedMessageOr(deleteTablesError, SAVE_ERROR));
        return;
      }

      const resolveSectionId = (sectionKey: string | null) =>
        sectionKey ? (keyToRealSectionId.get(sectionKey) ?? null) : null;

      const originalTableById = new Map(originalTablesForLayout.map((t) => [t.id, t]));
      const toInsertTables = draftTablesForLayout
        .filter((t) => t.id === null)
        .map((t) => ({
          restaurant_id: restaurant.id,
          layout_id: realLayoutId,
          section_id: resolveSectionId(t.sectionKey),
          name: t.name,
          seats: Number(t.seats),
          x: t.x,
          y: t.y,
          width: t.width,
          height: t.height,
        }));
      const toUpdateTables = draftTablesForLayout.filter((t): t is DraftTable & { id: string } => {
        if (t.id === null) return false;
        const original = originalTableById.get(t.id);
        if (!original) return true;
        const resolvedSectionId = resolveSectionId(t.sectionKey);
        return (
          original.name !== t.name ||
          original.seats !== Number(t.seats) ||
          original.section_id !== resolvedSectionId ||
          original.x !== t.x ||
          original.y !== t.y ||
          original.width !== t.width ||
          original.height !== t.height
        );
      });

      const { error: insertTablesError } = toInsertTables.length
        ? await supabase.from("tables").insert(toInsertTables)
        : { error: null };

      const updateTableResults = insertTablesError
        ? []
        : await Promise.all(
            toUpdateTables.map((t) =>
              supabase
                .from("tables")
                .update({
                  name: t.name,
                  seats: Number(t.seats),
                  section_id: resolveSectionId(t.sectionKey),
                  x: t.x,
                  y: t.y,
                  width: t.width,
                  height: t.height,
                })
                .eq("id", t.id),
            ),
          );
      const tablesError = insertTablesError ?? updateTableResults.map((r) => r.error).find((e) => e !== null) ?? null;

      if (tablesError) {
        setLoading(false);
        setError(SAVE_ERROR);
        return;
      }
    }

    // restaurants.capacity and sections.capacity are only ever written here
    // in "no sections, no active layout" mode - the plain manually-typed
    // number. Whenever sections or an active layout exist, capacity is
    // shown live, computed straight from sections/tables on every render
    // (never read from these columns), so those columns are simply left
    // untouched - holding whatever was last manually set, ready to fall
    // back to if the sections/layout driving the live number are removed
    // later. (This means code outside this form can no longer just read
    // restaurants.capacity/sections.capacity and trust it - it needs to
    // compute it the same way this form does whenever sections or an
    // active layout exist.)
    if (!hasActiveLayouts && !hasSections) {
      const { error: capacityError } = await supabase
        .from("restaurants")
        .update({ capacity: capacity ? Number(capacity) : null })
        .eq("id", restaurant.id);

      if (capacityError) {
        setLoading(false);
        setError(raisedMessageOr(capacityError, SAVE_ERROR));
        return;
      }
    }

    setLoading(false);
    router.push("/owner");
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="w-full max-w-3xl space-y-6 rounded-lg border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-700 dark:bg-stone-800"
    >
      <div className="space-y-1">
        <label htmlFor="name" className="block text-sm font-medium">
          Naziv restorana
        </label>
        <input
          id="name"
          required
          value={name}
          onChange={(event) => setName(event.target.value)}
          className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
        />
      </div>

      <div className="space-y-1">
        <label htmlFor="default-stay-minutes" className="block text-sm font-medium">
          Trajanje rezervacije (min)
        </label>
        <input
          id="default-stay-minutes"
          type="number"
          min={1}
          required
          value={defaultStayMinutes}
          onChange={(event) => setDefaultStayMinutes(event.target.value)}
          className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
        />
        {/* No native max - browsers block submission with an unlocalized
            message before this form's own Serbian error can show (see
            DEFAULT_STAY_MINUTES_RANGE_ERROR above). Every actual
            reservation ends up bound to 30-180 minutes regardless, since
            this value is only ever a fallback when a customer leaves
            "Trajanje" blank. */}
        <p className="text-xs text-stone-500 dark:text-stone-400">Između 30 i 180 minuta.</p>
      </div>

      <div className="space-y-2">
        <h2 className="text-sm font-medium">Radno vreme</h2>
        <RestaurantHoursCalendar value={blocks} onChange={setBlocks} />
      </div>

      <div className="space-y-1">
        <label htmlFor="capacity" className="block text-sm font-medium">
          Ukupan kapacitet
        </label>
        {hasActiveLayouts || hasSections ? (
          <output
            id="capacity"
            className="inline-block rounded-md border border-stone-300 bg-stone-100 px-3 py-2 text-base text-stone-600 dark:border-stone-600 dark:bg-stone-700 dark:text-stone-400"
          >
            {hasActiveLayouts ? liveCapacity.total : derivedSectionsCapacity}
          </output>
        ) : (
          <input
            id="capacity"
            type="number"
            min={1}
            value={capacity}
            onChange={(event) => setCapacity(event.target.value)}
            className="w-24 rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100"
          />
        )}
        {(hasActiveLayouts || hasSections) && (
          <p className="text-xs text-stone-600 dark:text-stone-400">
            {hasActiveLayouts
              ? "Kapacitet se izračunava iz aktivnih rasporeda stolova."
              : "Kapacitet se izračunava iz sekcija."}
          </p>
        )}
      </div>

      <div className="space-y-3 rounded-lg border border-stone-200 bg-stone-50 p-4 dark:border-stone-700 dark:bg-stone-900/40">
        <h2 className="text-sm font-medium">Sekcije</h2>
        <SectionsEditor
          value={draftSections}
          onChange={handleSectionsChange}
          capacityReadOnly={hasActiveLayouts}
          liveCapacities={hasActiveLayouts ? liveCapacity.bySection : undefined}
        />
      </div>

      <div className="space-y-3 rounded-lg border border-stone-200 bg-stone-50 p-4 dark:border-stone-700 dark:bg-stone-900/40">
        <h2 className="text-sm font-medium">Raspored stolova</h2>
        <LayoutsEditor
          value={draftLayouts}
          onChange={handleLayoutsChange}
          editingKey={editingLayoutKey}
          onEditingKeyChange={setEditingLayoutKey}
        />
        {editingLayoutKey && (
          <TableLayoutEditor
            key={editingLayoutKey}
            value={editingLayoutTables}
            onChange={handleEditingLayoutTablesChange}
            sections={draftSections.map((s) => ({ key: s.key, name: s.name, colorIndex: s.colorIndex }))}
          />
        )}
      </div>

      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}

      <button
        type="submit"
        disabled={loading}
        className="w-full rounded-md bg-accent px-3 py-2 text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
      >
        {loading ? "Čuvanje..." : "Sačuvaj izmene"}
      </button>
    </form>
  );
}
