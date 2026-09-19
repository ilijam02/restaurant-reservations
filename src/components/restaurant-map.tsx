"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import type { Marker } from "maplibre-gl";
import { DEFAULT_MAP_CENTER, DEFAULT_MAP_ZOOM, PLACE_ZOOM, createPinElement } from "@/lib/map";
import { useMap } from "@/lib/use-map";

export type MapRestaurant = {
  id: string;
  name: string;
  address: string | null;
  latitude: number;
  longitude: number;
};

// Popup body for one restaurant: name, address, and a link to its page (the
// same page a card on the customer home opens). Built as DOM because MapLibre
// popups take a node, not React. Text goes in through textContent, never
// innerHTML - names and addresses are owner-typed.
function createPopupContent(restaurant: MapRestaurant, onOpen: (href: string) => void): HTMLElement {
  const href = `/customer/restaurants/${restaurant.id}`;

  const root = document.createElement("div");
  root.className = "space-y-1";

  const name = document.createElement("p");
  name.className = "text-base font-semibold";
  name.textContent = restaurant.name;
  root.append(name);

  if (restaurant.address) {
    const address = document.createElement("p");
    address.className = "text-sm text-stone-600 dark:text-stone-400";
    address.textContent = restaurant.address;
    root.append(address);
  }

  const link = document.createElement("a");
  link.href = href;
  link.textContent = "Otvori restoran";
  link.className =
    "mt-1 inline-block rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-accent-foreground hover:opacity-90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent";
  link.addEventListener("click", (event) => {
    // Let ctrl/cmd/shift/middle-click open a new tab the normal way; a plain
    // click stays a client-side navigation instead of a full page load.
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    onOpen(href);
  });
  root.append(link);

  return root;
}

// Pins for every restaurant that has a location. `focusId` (the "Otvori na
// mapi" button on a restaurant page) starts the camera on that restaurant's
// pin and opens its popup; without it the camera frames all the pins.
export function RestaurantMap({ restaurants, focusId }: { restaurants: MapRestaurant[]; focusId: string | null }) {
  const router = useRouter();
  const containerRef = useRef<HTMLDivElement>(null);
  const markersRef = useRef<Map<string, Marker>>(new Map());
  const openedFocusRef = useRef<string | null>(null);

  const focused = restaurants.find((r) => r.id === focusId) ?? null;
  const mapInstance = useMap(
    containerRef,
    focused ? [focused.longitude, focused.latitude] : DEFAULT_MAP_CENTER,
    focused ? PLACE_ZOOM : DEFAULT_MAP_ZOOM,
  );

  const navigate = useRef(router.push);
  useEffect(() => {
    navigate.current = router.push;
  });

  // One marker per restaurant, rebuilt only when the list itself changes.
  useEffect(() => {
    if (!mapInstance) return;
    const { map, lib } = mapInstance;
    const markers = markersRef.current;

    for (const restaurant of restaurants) {
      const popup = new lib.Popup({ offset: [0, -42], maxWidth: "260px", closeButton: false }).setDOMContent(
        createPopupContent(restaurant, (href) => navigate.current(href)),
      );
      const marker = new lib.Marker({ element: createPinElement(restaurant.name), anchor: "bottom" })
        .setLngLat([restaurant.longitude, restaurant.latitude])
        .setPopup(popup)
        .addTo(map);
      markers.set(restaurant.id, marker);
    }

    // No specific restaurant asked for: frame all of them.
    if (!focused && restaurants.length > 0) {
      const bounds = new lib.LngLatBounds();
      for (const restaurant of restaurants) bounds.extend([restaurant.longitude, restaurant.latitude]);
      map.fitBounds(bounds, { padding: 70, maxZoom: 15, animate: false });
    }

    return () => {
      for (const marker of markers.values()) marker.remove();
      markers.clear();
      openedFocusRef.current = null;
    };
    // `focused` only decides the initial framing above; the effect below
    // handles it changing afterwards, so it isn't a dependency here.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mapInstance, restaurants]);

  // Move to (and open) the focused restaurant's pin - on first load, and again
  // if the page is reached with a different ?restaurant= while already open.
  useEffect(() => {
    if (!mapInstance || !focused || openedFocusRef.current === focused.id) return;
    const marker = markersRef.current.get(focused.id);
    if (!marker) return;
    openedFocusRef.current = focused.id;
    mapInstance.map.flyTo({ center: [focused.longitude, focused.latitude], zoom: PLACE_ZOOM });
    if (!marker.getPopup()?.isOpen()) marker.togglePopup();
  }, [mapInstance, focused, restaurants]);

  // 20% wider than the original max-w-5xl (1024px); the height follows the
  // width at 16:9 (aspect-video), so the map keeps its shape at any window size.
  return (
    <div className="w-full max-w-[1229px] space-y-3">
      {restaurants.length === 0 && (
        <p className="text-stone-600 dark:text-stone-400">Nijedan restoran još nije postavio lokaciju na mapi.</p>
      )}
      <div
        ref={containerRef}
        role="application"
        aria-label="Mapa restorana"
        className="aspect-video w-full overflow-hidden rounded-lg border border-stone-200 dark:border-stone-700"
      />
    </div>
  );
}
