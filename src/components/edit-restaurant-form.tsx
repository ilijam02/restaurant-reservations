"use client";

import { useState, type FormEvent } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { RestaurantHoursCalendar, type HourBlock } from "@/components/restaurant-hours-calendar";
import { SectionsEditor, type DraftSection } from "@/components/sections-editor";
import { LayoutsEditor, type LayoutOption } from "@/components/layouts-editor";
import { writeDerivedCapacity } from "@/lib/capacity-cascade";

type Restaurant = {
  id: string;
  name: string;
  capacity: number | null;
  default_stay_minutes: number;
  current_layout_id: string | null;
};

type HoursRow = {
  day_of_week: number;
  start_minute: number;
  end_minute: number;
};

type SectionRow = { id: string; name: string; capacity: number; color_index: number };
type TableRow = { id: string; section_id: string | null };
type LayoutRow = { id: string; name: string };

const DUPLICATE_SECTION_NAME_ERROR = "Sekcija sa ovim nazivom već postoji.";
const SECTIONS_SAVE_ERROR = "Čuvanje sekcija nije uspelo. Pokušajte ponovo.";
const SECTION_HAS_TABLES_ERROR =
  "Ne možete obrisati sekciju dok joj je dodeljen sto - prvo promenite ili uklonite te stolove u rasporedu stolova.";
const LAYOUT_MISSING_SECTION_ERROR =
  "Izabrani raspored ima sto bez sekcije - dodelite mu sekciju u rasporedu stolova pre nego što ga izaberete kao trenutni.";
const SAVE_ERROR = "Čuvanje izmena nije uspelo. Pokušajte ponovo.";

function initialBlocks(hours: HoursRow[]): HourBlock[] {
  return hours.map((h) => ({
    id: crypto.randomUUID(),
    dayOfWeek: h.day_of_week,
    start: h.start_minute,
    end: h.end_minute,
  }));
}

function initialDraftSections(sections: SectionRow[]): DraftSection[] {
  return sections.map((s) => ({
    key: crypto.randomUUID(),
    id: s.id,
    name: s.name,
    capacity: s.capacity.toString(),
    colorIndex: s.color_index,
  }));
}

function sumDraftCapacity(sections: DraftSection[]) {
  return sections.reduce((sum, s) => sum + (Number(s.capacity) || 0), 0);
}

export function EditRestaurantForm({
  restaurant,
  hours,
  sections,
  tables,
  layouts,
}: {
  restaurant: Restaurant;
  hours: HoursRow[];
  sections: SectionRow[];
  tables: TableRow[];
  layouts: LayoutRow[];
}) {
  const router = useRouter();
  const [name, setName] = useState(restaurant.name);
  const [capacity, setCapacity] = useState(restaurant.capacity?.toString() ?? "");
  const [defaultStayMinutes, setDefaultStayMinutes] = useState(
    restaurant.default_stay_minutes.toString(),
  );
  const [blocks, setBlocks] = useState<HourBlock[]>(() => initialBlocks(hours));
  const [draftSections, setDraftSections] = useState<DraftSection[]>(() => initialDraftSections(sections));
  const [draftLayouts, setDraftLayouts] = useState<LayoutOption[]>(layouts);
  const [currentLayoutId, setCurrentLayoutId] = useState<string | null>(restaurant.current_layout_id);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  // Once a layout is chosen as current, capacity (both here and per-section)
  // is derived from that layout's tables, not editable here at all.
  const hasLayout = currentLayoutId !== null;
  const hasSections = draftSections.length > 0;
  const derivedCapacity = sumDraftCapacity(draftSections);
  const currentLayout = draftLayouts.find((l) => l.id === currentLayoutId) ?? null;

  function handleSectionsChange(next: DraftSection[]) {
    // Removing the last section unfreezes capacity back to a manually-typed
    // value, seeded at what it was derived as right before the removal.
    // Only relevant pre-layout - once a layout is current, capacity never
    // comes from this draft at all.
    if (!hasLayout && draftSections.length > 0 && next.length === 0) {
      setCapacity(sumDraftCapacity(draftSections).toString());
    }
    setDraftSections(next);
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setLoading(true);

    const supabase = createClient();

    const removedIds = sections
      .filter((original) => !draftSections.some((d) => d.id === original.id))
      .map((s) => s.id);

    // A section still holding tables can't be deleted while other sections
    // would remain afterward - those tables would be left without a
    // section, which is only ever valid when the restaurant has none at
    // all. Deleting down to zero sections is fine (tables just become
    // unassigned, which "layout without sections" already allows).
    if (removedIds.length && draftSections.length > 0) {
      const blockedId = removedIds.find((id) => tables.some((t) => t.section_id === id));
      if (blockedId) {
        setLoading(false);
        setError(SECTION_HAS_TABLES_ERROR);
        return;
      }
    }

    // Layouts are created immediately elsewhere (LayoutsEditor), not staged
    // here - every entry in draftLayouts already has a real id, so choosing
    // one as current is just picking which existing id to point at.
    const finalCurrentLayoutId = currentLayoutId;

    // Switching to a different current layout (including choosing one for
    // the first time) means capacity now has a new source of truth -
    // validate and recompute it from that layout's actual tables before
    // committing to it.
    const layoutSelectionChanged = finalCurrentLayoutId !== restaurant.current_layout_id;
    let layoutTables: { section_id: string | null; seats: number }[] = [];
    if (layoutSelectionChanged && finalCurrentLayoutId) {
      const { data, error: layoutTablesError } = await supabase
        .from("tables")
        .select("section_id, seats")
        .eq("layout_id", finalCurrentLayoutId);

      if (layoutTablesError) {
        setLoading(false);
        setError(SAVE_ERROR);
        return;
      }
      layoutTables = data ?? [];

      if (hasSections && layoutTables.some((t) => t.section_id === null)) {
        setLoading(false);
        setError(LAYOUT_MISSING_SECTION_ERROR);
        return;
      }
    }

    const { error: restaurantError } = await supabase
      .from("restaurants")
      .update({ name, default_stay_minutes: Number(defaultStayMinutes), current_layout_id: finalCurrentLayoutId })
      .eq("id", restaurant.id);

    if (restaurantError) {
      setLoading(false);
      setError(SAVE_ERROR);
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

    const { error: deleteSectionsError } = removedIds.length
      ? await supabase.from("sections").delete().in("id", removedIds)
      : { error: null };

    if (deleteSectionsError) {
      setLoading(false);
      setError(SECTIONS_SAVE_ERROR);
      return;
    }

    const originalById = new Map(sections.map((s) => [s.id, s]));
    const toInsert = draftSections
      .filter((s) => s.id === null)
      .map((s) => ({
        restaurant_id: restaurant.id,
        name: s.name,
        capacity: hasLayout ? 0 : Number(s.capacity),
        color_index: s.colorIndex,
      }));
    // Only rows that actually changed - skips unnecessary writes, and keeps
    // the temp-rename dance below limited to rows that need it.
    const toUpdate = draftSections.filter((s): s is DraftSection & { id: string } => {
      if (s.id === null) return false;
      const original = originalById.get(s.id);
      if (!original) return true;
      return original.name !== s.name || (!hasLayout && original.capacity !== Number(s.capacity));
    });

    // Renaming sections can swap names between two existing rows (e.g. "A"
    // <-> "B"), which the unique (restaurant_id, name) constraint would
    // reject if applied directly - one row's new name transiently collides
    // with the other's still-current name. Stage every changed row through
    // a name guaranteed unique (its own id) first, so no two writes in this
    // whole reconciliation can ever transiently collide, then insert new
    // rows (now free of any name they're reclaiming) before setting the
    // changed rows to their real final names.
    const stageRenameResults = toUpdate.length
      ? await Promise.all(
          toUpdate.map((s) => supabase.from("sections").update({ name: `__tmp_${s.id}` }).eq("id", s.id)),
        )
      : [];
    const stageRenameError = stageRenameResults.map((r) => r.error).find((e) => e !== null) ?? null;

    if (stageRenameError) {
      setLoading(false);
      setError(SECTIONS_SAVE_ERROR);
      return;
    }

    const { error: insertSectionsError } = toInsert.length
      ? await supabase.from("sections").insert(toInsert)
      : { error: null };

    const updateResults = insertSectionsError
      ? []
      : await Promise.all(
          toUpdate.map((s) =>
            supabase
              .from("sections")
              .update(hasLayout ? { name: s.name } : { name: s.name, capacity: Number(s.capacity) })
              .eq("id", s.id),
          ),
        );
    const sectionsError = insertSectionsError ?? updateResults.map((r) => r.error).find((e) => e !== null) ?? null;

    if (sectionsError) {
      setLoading(false);
      setError(sectionsError.code === "23505" ? DUPLICATE_SECTION_NAME_ERROR : SECTIONS_SAVE_ERROR);
      return;
    }

    if (hasLayout) {
      // Only re-derive capacity when the current layout actually changed -
      // otherwise it's already correct from whenever it was last computed
      // (a table-layout save, or an earlier layout switch).
      if (layoutSelectionChanged && finalCurrentLayoutId) {
        const survivingSections = draftSections
          .filter((s): s is DraftSection & { id: string } => s.id !== null)
          .map((s) => ({ id: s.id }));
        const { error: capacityError } = await writeDerivedCapacity(
          supabase,
          restaurant.id,
          survivingSections,
          layoutTables.map((t) => ({ sectionId: t.section_id, seats: t.seats })),
        );

        if (capacityError) {
          setLoading(false);
          setError(SAVE_ERROR);
          return;
        }
      }
    } else {
      const { error: capacityError } = await supabase
        .from("restaurants")
        .update({ capacity: hasSections ? derivedCapacity : capacity ? Number(capacity) : null })
        .eq("id", restaurant.id);

      if (capacityError) {
        setLoading(false);
        setError(SAVE_ERROR);
        return;
      }
    }

    setLoading(false);
    router.push("/owner");
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="w-full max-w-2xl space-y-6 rounded-lg border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-700 dark:bg-stone-800"
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
      </div>

      <div className="space-y-2">
        <h2 className="text-sm font-medium">Radno vreme</h2>
        <RestaurantHoursCalendar value={blocks} onChange={setBlocks} />
      </div>

      <div className="space-y-1">
        <label htmlFor="capacity" className="block text-sm font-medium">
          Ukupan kapacitet
        </label>
        {hasLayout || hasSections ? (
          <output
            id="capacity"
            className="inline-block rounded-md border border-stone-300 bg-stone-100 px-3 py-2 text-base text-stone-600 dark:border-stone-600 dark:bg-stone-700 dark:text-stone-400"
          >
            {hasLayout ? restaurant.capacity : derivedCapacity}
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
        {(hasLayout || hasSections) && (
          <p className="text-xs text-stone-600 dark:text-stone-400">
            {hasLayout ? "Kapacitet se izračunava iz rasporeda stolova." : "Kapacitet se izračunava iz sekcija."}
          </p>
        )}
      </div>

      <div className="space-y-3 rounded-lg border border-stone-200 bg-stone-50 p-4 dark:border-stone-700 dark:bg-stone-900/40">
        <h2 className="text-sm font-medium">Sekcije</h2>
        <SectionsEditor value={draftSections} onChange={handleSectionsChange} capacityReadOnly={hasLayout} />
      </div>

      <div className="space-y-3 rounded-lg border border-stone-200 bg-stone-50 p-4 dark:border-stone-700 dark:bg-stone-900/40">
        <div className="flex items-center justify-between gap-4">
          <h2 className="text-sm font-medium">Raspored stolova</h2>
          {currentLayout && (
            <Link
              href={`/owner/restaurants/${restaurant.id}/layout/${currentLayout.id}`}
              className="rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
            >
              Uredi raspored
            </Link>
          )}
        </div>
        <LayoutsEditor
          restaurantId={restaurant.id}
          value={draftLayouts}
          onChange={setDraftLayouts}
          currentId={currentLayoutId}
          onCurrentIdChange={setCurrentLayoutId}
        />
      </div>

      {error && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      )}

      <div className="flex items-center gap-4">
        <button
          type="submit"
          disabled={loading}
          className="flex-1 rounded-md bg-accent px-3 py-2 text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
        >
          {loading ? "Čuvanje..." : "Sačuvaj izmene"}
        </button>
        <Link
          href="/owner"
          className="text-sm font-medium text-stone-600 hover:underline dark:text-stone-400"
        >
          Nazad
        </Link>
      </div>
    </form>
  );
}
