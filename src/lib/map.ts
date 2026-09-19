// Shared bits of the map feature (owner location picker + customer map).
// MapLibre GL JS renders it, OpenFreeMap serves the tiles: free, no API key,
// no request limits, commercial use allowed (openfreemap.org). If it ever
// needs swapping, the style URLs below are the only coupling.

export const MAP_STYLE_LIGHT = "https://tiles.openfreemap.org/styles/liberty";
// "fiord" (a slate blue) rather than OpenFreeMap's "dark" style, whose
// background is near-black - this app never uses near-black as a surface.
export const MAP_STYLE_DARK = "https://tiles.openfreemap.org/styles/fiord";

// Belgrade - where the map starts when there's nothing to show yet.
export const DEFAULT_MAP_CENTER: [number, number] = [20.4612, 44.8125]; // [lng, lat]
export const DEFAULT_MAP_ZOOM = 11;
// Zoom for "this one place": close enough to tell the streets apart.
export const PLACE_ZOOM = 16;

export function mapStyleFor(dark: boolean): string {
  return dark ? MAP_STYLE_DARK : MAP_STYLE_LIGHT;
}

// Address text and pin are independent values, so an owner can retype the
// address and forget to move the pin. This compares the address as it is now
// with the address the pin was last set for (ignoring case and spacing, which
// don't move a restaurant) so the form can warn about exactly that.
export function addressChangedSincePin(address: string, addressAtPin: string): boolean {
  const normalize = (value: string) => value.trim().replace(/\s+/g, " ").toLowerCase();
  return normalize(address) !== normalize(addressAtPin);
}

// The map page takes an optional restaurant to fly to, so the restaurant page's
// "Otvori na mapi" button and the map's own pins share one URL shape.
export function mapHrefForRestaurant(restaurantId: string): string {
  return `/customer/map?restaurant=${encodeURIComponent(restaurantId)}`;
}

// The marker is a plain DOM element (MapLibre positions it for us). It's a
// <button> so it's keyboard-focusable and announced with the restaurant's
// name. Fill comes from --accent, so it follows the OS theme without a dark:
// variant; the dark stroke keeps it readable against either map style.
export function createPinElement(label: string): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.setAttribute("aria-label", label);
  button.className =
    "block cursor-pointer rounded-full focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent";
  button.innerHTML = `
    <svg width="32" height="42" viewBox="0 0 32 42" aria-hidden="true" style="display:block;filter:drop-shadow(0 1px 2px rgb(0 0 0 / 0.4))">
      <path d="M16 1C8 1 2 7.2 2 15c0 10.5 14 25 14 25s14-14.5 14-25C30 7.2 24 1 16 1z" fill="var(--accent)" stroke="#1c1917" stroke-width="2"/>
      <circle cx="16" cy="15" r="5" fill="#1c1917"/>
    </svg>`;
  return button;
}
