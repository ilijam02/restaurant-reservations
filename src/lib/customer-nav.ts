// Shared across every /customer page that renders AppHeader's dropdown menu,
// so the link's label/href can't drift between pages. Left off the
// reservations page itself since linking to the current page is pointless.
export const CUSTOMER_MENU_ITEMS = [{ label: "Moje rezervacije", href: "/customer/reservations" }];
