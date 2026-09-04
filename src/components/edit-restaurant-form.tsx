"use client";

import { useState, type FormEvent } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { RestaurantHoursCalendar, type HourBlock } from "@/components/restaurant-hours-calendar";
import { SectionsEditor, type DraftSection } from "@/components/sections-editor";

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

type SectionRow = { id: string; name: string; capacity: number };

const DUPLICATE_SECTION_NAME_ERROR = "Sekcija sa ovim nazivom već postoji.";
const SECTIONS_SAVE_ERROR = "Čuvanje sekcija nije uspelo. Pokušajte ponovo.";

function initialBlocks(hours: HoursRow[]): HourBlock[] {
  return hours.map((h) => ({
    id: crypto.randomUUID(),
    dayOfWeek: h.day_of_week,
    start: h.start_minute,
    end: h.end_minute,
  }));
}

function initialDraftSections(sections: SectionRow[]): DraftSection[] {
  return sections.map((s) => ({ key: crypto.randomUUID(), id: s.id, name: s.name, capacity: s.capacity.toString() }));
}

function sumDraftCapacity(sections: DraftSection[]) {
  return sections.reduce((sum, s) => sum + (Number(s.capacity) || 0), 0);
}

export function EditRestaurantForm({
  restaurant,
  hours,
  sections,
}: {
  restaurant: Restaurant;
  hours: HoursRow[];
  sections: SectionRow[];
}) {
  const router = useRouter();
  const [name, setName] = useState(restaurant.name);
  const [capacity, setCapacity] = useState(restaurant.capacity?.toString() ?? "");
  const [defaultStayMinutes, setDefaultStayMinutes] = useState(
    restaurant.default_stay_minutes.toString(),
  );
  const [blocks, setBlocks] = useState<HourBlock[]>(() => initialBlocks(hours));
  const [draftSections, setDraftSections] = useState<DraftSection[]>(() => initialDraftSections(sections));
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const hasSections = draftSections.length > 0;
  const derivedCapacity = sumDraftCapacity(draftSections);

  function handleSectionsChange(next: DraftSection[]) {
    // Removing the last section unfreezes capacity back to a manually-typed
    // value, seeded at what it was derived as right before the removal.
    if (draftSections.length > 0 && next.length === 0) {
      setCapacity(sumDraftCapacity(draftSections).toString());
    }
    setDraftSections(next);
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setLoading(true);

    const supabase = createClient();

    // Capacity is written last, only once sections (its source of truth
    // once any exist) have actually been saved - writing it up front would
    // leave restaurants.capacity referencing a section total that was never
    // actually reached if a later step below fails.
    const { error: restaurantError } = await supabase
      .from("restaurants")
      .update({ name, default_stay_minutes: Number(defaultStayMinutes) })
      .eq("id", restaurant.id);

    if (restaurantError) {
      setLoading(false);
      setError("Čuvanje izmena nije uspelo. Pokušajte ponovo.");
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

    const removedIds = sections
      .filter((original) => !draftSections.some((d) => d.id === original.id))
      .map((s) => s.id);

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
      .map((s) => ({ restaurant_id: restaurant.id, name: s.name, capacity: Number(s.capacity) }));
    // Only rows that actually changed - skips unnecessary writes, and keeps
    // the temp-rename dance below limited to rows that need it.
    const toUpdate = draftSections.filter((s): s is DraftSection & { id: string } => {
      if (s.id === null) return false;
      const original = originalById.get(s.id);
      return !original || original.name !== s.name || original.capacity !== Number(s.capacity);
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
            supabase.from("sections").update({ name: s.name, capacity: Number(s.capacity) }).eq("id", s.id),
          ),
        );
    const sectionsError = insertSectionsError ?? updateResults.map((r) => r.error).find((e) => e !== null) ?? null;

    if (sectionsError) {
      setLoading(false);
      setError(sectionsError.code === "23505" ? DUPLICATE_SECTION_NAME_ERROR : SECTIONS_SAVE_ERROR);
      return;
    }

    const { error: capacityError } = await supabase
      .from("restaurants")
      .update({ capacity: hasSections ? derivedCapacity : capacity ? Number(capacity) : null })
      .eq("id", restaurant.id);

    setLoading(false);
    if (capacityError) {
      setError("Čuvanje izmena nije uspelo. Pokušajte ponovo.");
      return;
    }

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
        {hasSections ? (
          <output
            id="capacity"
            className="inline-block rounded-md border border-stone-300 bg-stone-100 px-3 py-2 text-base text-stone-600 dark:border-stone-600 dark:bg-stone-700 dark:text-stone-400"
          >
            {derivedCapacity}
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
        {hasSections && (
          <p className="text-xs text-stone-600 dark:text-stone-400">Kapacitet se izračunava iz sekcija.</p>
        )}
      </div>

      <div className="space-y-3 rounded-lg border border-stone-200 bg-stone-50 p-4 dark:border-stone-700 dark:bg-stone-900/40">
        <h2 className="text-sm font-medium">Sekcije</h2>
        <SectionsEditor value={draftSections} onChange={handleSectionsChange} />
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
