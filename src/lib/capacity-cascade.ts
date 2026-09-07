import type { SupabaseClient } from "@supabase/supabase-js";

type SectionRef = { id: string };
type TableRef = { sectionId: string | null; seats: number };

// Once a restaurant has a current layout, both a section's capacity and
// the restaurant's total are derived from that layout's tables - this
// recomputes and writes both, given whatever set of tables is now the
// source of truth (a layout's live tables, or the tables a just-deleted
// layout had right before deletion, for the "unfreeze" case).
export async function writeDerivedCapacity(
  supabase: SupabaseClient,
  restaurantId: string,
  sections: SectionRef[],
  tables: TableRef[],
) {
  const sumsBySection = new Map<string, number>();
  for (const t of tables) {
    if (t.sectionId) sumsBySection.set(t.sectionId, (sumsBySection.get(t.sectionId) ?? 0) + t.seats);
  }

  const sectionResults = await Promise.all(
    sections.map((s) => supabase.from("sections").update({ capacity: sumsBySection.get(s.id) ?? 0 }).eq("id", s.id)),
  );
  const sectionError = sectionResults.map((r) => r.error).find((e) => e !== null) ?? null;
  if (sectionError) return { error: sectionError };

  const total = tables.reduce((sum, t) => sum + t.seats, 0);
  const { error } = await supabase.from("restaurants").update({ capacity: total }).eq("id", restaurantId);
  return { error };
}
