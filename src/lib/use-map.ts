import "maplibre-gl/dist/maplibre-gl.css";
import { useEffect, useRef, useState, type RefObject } from "react";
import type { Map as MapLibreMap } from "maplibre-gl";
import { mapStyleFor } from "@/lib/map";

type MapLibre = typeof import("maplibre-gl");
export type MapInstance = { map: MapLibreMap; lib: MapLibre };

// Creates a MapLibre map in `container` and hands it back once it exists
// (null before that, and again after unmount). maplibre-gl needs `window`, so
// it's imported dynamically inside the effect - never during server render.
// `center` ([lng, lat]) and `zoom` are the *initial* view only; move the
// camera afterwards through the returned map. The style follows the OS
// light/dark setting, like the rest of the app.
export function useMap(
  container: RefObject<HTMLDivElement | null>,
  center: [number, number],
  zoom: number,
): MapInstance | null {
  const [instance, setInstance] = useState<MapInstance | null>(null);
  const initialView = useRef({ center, zoom });

  useEffect(() => {
    let cancelled = false;
    let map: MapLibreMap | null = null;
    let colorScheme: MediaQueryList | null = null;
    let onSchemeChange: ((event: MediaQueryListEvent) => void) | null = null;

    void import("maplibre-gl").then((lib) => {
      if (cancelled || !container.current) return;

      colorScheme = window.matchMedia("(prefers-color-scheme: dark)");
      const created = new lib.Map({
        container: container.current,
        style: mapStyleFor(colorScheme.matches),
        center: initialView.current.center,
        zoom: initialView.current.zoom,
      });
      created.addControl(new lib.NavigationControl({ showCompass: false }), "top-right");

      onSchemeChange = (event) => created.setStyle(mapStyleFor(event.matches));
      colorScheme.addEventListener("change", onSchemeChange);

      map = created;
      setInstance({ map: created, lib });
    });

    return () => {
      cancelled = true;
      if (colorScheme && onSchemeChange) colorScheme.removeEventListener("change", onSchemeChange);
      map?.remove();
      setInstance(null);
    };
  }, [container]);

  return instance;
}
