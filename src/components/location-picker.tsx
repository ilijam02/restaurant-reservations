"use client";

import { useEffect, useRef, useState } from "react";
import type { Marker } from "maplibre-gl";
import { geocodeAddressAction } from "@/app/owner/restaurants/[id]/edit/actions";
import { DEFAULT_MAP_CENTER, DEFAULT_MAP_ZOOM, PLACE_ZOOM, createPinElement } from "@/lib/map";
import { useMap } from "@/lib/use-map";

export type LocationPosition = { latitude: number; longitude: number };

const BUTTON_CLASSES =
  "rounded-md border border-stone-300 px-3 py-2 text-sm hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:hover:bg-stone-700";

// Address field + a map the owner can put a pin on. "Pronađi na mapi" turns
// the typed address into a pin (an explicit click, never as-you-type - see
// lib/geocode.ts), and the pin can then be dragged or re-placed by clicking
// the map, since a geocoder can be off by a street or miss an address
// entirely. The address text and the pin are independent values: editing one
// never rewrites the other.
export function LocationPicker({
  address,
  onAddressChange,
  position,
  onPositionChange,
  disabled = false,
}: {
  address: string;
  onAddressChange: (address: string) => void;
  position: LocationPosition | null;
  onPositionChange: (position: LocationPosition | null) => void;
  disabled?: boolean;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const markerRef = useRef<Marker | null>(null);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);

  const mapInstance = useMap(
    containerRef,
    position ? [position.longitude, position.latitude] : DEFAULT_MAP_CENTER,
    position ? PLACE_ZOOM : DEFAULT_MAP_ZOOM,
  );

  // The map's own listeners are attached once, so they read the newest props
  // through this ref instead of capturing the render they were created in.
  const latest = useRef({ onPositionChange, disabled });
  useEffect(() => {
    latest.current = { onPositionChange, disabled };
  });

  // Click anywhere on the map to place (or move) the pin.
  useEffect(() => {
    if (!mapInstance) return;
    const { map } = mapInstance;
    const handleClick = (event: { lngLat: { wrap: () => { lat: number; lng: number } } }) => {
      if (latest.current.disabled) return;
      const { lat, lng } = event.lngLat.wrap();
      latest.current.onPositionChange({ latitude: lat, longitude: lng });
    };
    map.on("click", handleClick);
    return () => {
      map.off("click", handleClick);
    };
  }, [mapInstance]);

  // Keep the marker in step with `position`: created on first placement,
  // moved afterwards, removed when the pin is cleared.
  useEffect(() => {
    if (!mapInstance) return;
    const { map, lib } = mapInstance;

    if (!position) {
      markerRef.current?.remove();
      markerRef.current = null;
      return;
    }

    if (!markerRef.current) {
      const marker = new lib.Marker({
        element: createPinElement("Pin restorana"),
        anchor: "bottom",
        draggable: true,
      })
        .setLngLat([position.longitude, position.latitude])
        .addTo(map);
      marker.on("dragend", () => {
        if (latest.current.disabled) return;
        const { lat, lng } = marker.getLngLat().wrap();
        latest.current.onPositionChange({ latitude: lat, longitude: lng });
      });
      markerRef.current = marker;
    } else {
      markerRef.current.setLngLat([position.longitude, position.latitude]);
    }
  }, [mapInstance, position]);

  // The marker belongs to a map that's about to be torn down.
  useEffect(() => {
    if (mapInstance) return;
    markerRef.current = null;
  }, [mapInstance]);

  useEffect(() => {
    markerRef.current?.setDraggable(!disabled);
  }, [disabled, position]);

  async function handleSearch() {
    if (!address.trim() || searching) return;
    setSearching(true);
    setSearchError(null);
    const outcome = await geocodeAddressAction(address);
    setSearching(false);
    if (!outcome.ok) {
      setSearchError(outcome.error);
      return;
    }
    onPositionChange(outcome.result);
    mapInstance?.map.flyTo({ center: [outcome.result.longitude, outcome.result.latitude], zoom: PLACE_ZOOM });
  }

  return (
    <div className="space-y-2">
      <label htmlFor="address" className="block text-sm font-medium">
        Adresa
      </label>
      <div className="flex gap-2">
        <input
          id="address"
          value={address}
          disabled={disabled}
          maxLength={300}
          placeholder="npr. Knez Mihailova 1, Beograd"
          onChange={(event) => onAddressChange(event.target.value)}
          // Enter here would otherwise submit the whole edit form.
          onKeyDown={(event) => {
            if (event.key !== "Enter") return;
            event.preventDefault();
            void handleSearch();
          }}
          className="min-w-0 flex-1 rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500"
        />
        <button
          type="button"
          disabled={disabled || searching || !address.trim()}
          onClick={() => void handleSearch()}
          className={`${BUTTON_CLASSES} shrink-0`}
        >
          {searching ? "Tražim..." : "Pronađi na mapi"}
        </button>
      </div>
      {searchError && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {searchError}
        </p>
      )}

      <div
        ref={containerRef}
        role="application"
        aria-label="Mapa za izbor lokacije restorana"
        className="h-72 w-full overflow-hidden rounded-md border border-stone-300 dark:border-stone-600"
      />

      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-stone-600 dark:text-stone-400">
          {position
            ? "Prevucite pin ili kliknite na mapu da podesite tačnu lokaciju."
            : "Pronađite adresu ili kliknite na mapu da postavite pin. Bez pina restoran se ne prikazuje na mapi."}
        </p>
        {position && (
          <button
            type="button"
            disabled={disabled}
            onClick={() => onPositionChange(null)}
            className={`${BUTTON_CLASSES} text-red-600 dark:text-red-400`}
          >
            Ukloni pin
          </button>
        )}
      </div>
    </div>
  );
}
