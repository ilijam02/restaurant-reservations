"use client";

import { useState } from "react";

// An existing layout's key is its own id (stable, no lookup needed to
// cross-reference); a new, not-yet-saved layout gets a random key until
// it's actually inserted. isActive is independent of which layout is
// currently open on the canvas (editingKey) - a restaurant can have
// several active layouts at once (e.g. one per floor), all contributing to
// capacity, while only one has its canvas open at a time.
export type DraftLayout = { key: string; id: string | null; name: string; isActive: boolean };

export function LayoutsEditor({
  value,
  onChange,
  editingKey,
  onEditingKeyChange,
}: {
  value: DraftLayout[];
  onChange: (next: DraftLayout[]) => void;
  editingKey: string | null;
  onEditingKeyChange: (key: string | null) => void;
}) {
  const [newName, setNewName] = useState("");

  const activeNames = value.filter((l) => l.isActive).map((l) => l.name);
  const editingLayout = value.find((l) => l.key === editingKey) ?? null;

  function addLayout() {
    const name = newName.trim();
    if (!name) return;
    // Defaults to inactive - activating is a deliberate choice, but it's
    // still opened on the canvas right away so tables can be added to it
    // immediately.
    const layout: DraftLayout = { key: crypto.randomUUID(), id: null, name, isActive: false };
    onChange([...value, layout]);
    onEditingKeyChange(layout.key);
    setNewName("");
  }

  function removeCurrent() {
    if (!editingKey) return;
    const next = value.filter((l) => l.key !== editingKey);
    onChange(next);
    onEditingKeyChange(next[0]?.key ?? null);
  }

  function toggleActive() {
    if (!editingKey) return;
    onChange(value.map((l) => (l.key === editingKey ? { ...l, isActive: !l.isActive } : l)));
  }

  return (
    <div className="space-y-2">
      <p className="text-sm text-stone-600 dark:text-stone-400">
        Aktivni rasporedi: {activeNames.length > 0 ? activeNames.join(", ") : "nijedan"}
      </p>
      {value.length === 0 ? (
        <p className="text-sm text-stone-600 dark:text-stone-400">Nema još rasporeda.</p>
      ) : (
        <div className="flex gap-2">
          <label htmlFor="editing-layout" className="sr-only">
            Raspored za uređivanje
          </label>
          <select
            id="editing-layout"
            value={editingKey ?? ""}
            onChange={(event) => onEditingKeyChange(event.target.value)}
            className="flex-1 rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100"
          >
            <option value="" disabled>
              Izaberi raspored
            </option>
            {value.map((layout) => (
              <option key={layout.key} value={layout.key}>
                {layout.name}
              </option>
            ))}
          </select>
          {editingLayout && (
            <button
              type="button"
              onClick={toggleActive}
              className="shrink-0 rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
            >
              {editingLayout.isActive ? "Deaktiviraj" : "Aktiviraj"}
            </button>
          )}
          {editingKey && (
            <button
              type="button"
              onClick={removeCurrent}
              className="shrink-0 rounded-md border border-stone-300 px-3 py-1 text-sm text-red-600 hover:bg-stone-100 dark:border-stone-600 dark:text-red-400 dark:hover:bg-stone-700"
            >
              Obriši raspored
            </button>
          )}
        </div>
      )}
      <div className="flex gap-2">
        <label htmlFor="new-layout-name" className="sr-only">
          Naziv novog rasporeda
        </label>
        <input
          id="new-layout-name"
          value={newName}
          onChange={(event) => setNewName(event.target.value)}
          placeholder="Naziv novog rasporeda"
          className="flex-1 rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
        />
        <button
          type="button"
          onClick={addLayout}
          className="shrink-0 rounded-md border border-stone-300 px-3 py-1 text-sm hover:bg-stone-100 dark:border-stone-600 dark:hover:bg-stone-700"
        >
          Dodaj raspored
        </button>
      </div>
    </div>
  );
}
