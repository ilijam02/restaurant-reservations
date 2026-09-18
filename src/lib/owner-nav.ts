// Shared across every /owner page that renders AppHeader's dropdown menu,
// so the link's label/href can't drift between pages. Left off the
// all-reservations page itself since linking to the current page is pointless.
export const OWNER_MENU_ITEMS = [{ label: "Sve rezervacije", href: "/owner/reservations" }];
