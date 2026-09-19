// The PostgREST select string behind every reservations list (customer's own,
// an owner's per-restaurant and all-restaurants views), so they all embed the
// same shape ReservationRow describes. orders is a reverse join on
// orders.reservation_id; only confirmed orders ever carry one (set once by
// create_reservation()'s p_order_id finalization, cancelled along with the
// reservation by cancel_reservation()), so at most one per reservation in
// practice even though the FK itself isn't unique.
//
// Built from one template so the two variants can't drift apart: the owner's
// lists embed the restaurant with !inner, which turns
// `.is("restaurants.archived_at", null)` into a filter on the reservations
// themselves (archived restaurants' reservations drop out) instead of only
// nulling the embed.
function reservationListSelect(restaurantEmbed: string) {
  return `id, customer_id, cancelled_by, party_size, starts_at, ends_at, status, ${restaurantEmbed}, reservation_tables(tables(name)), reservation_sections(party_size, sections(name)), orders(status, items:order_items(id, item_name, unit_price, quantity, choices:order_item_choices(option_name, choice_name, price_delta)))`;
}

export const RESERVATION_LIST_SELECT = reservationListSelect("restaurants(name)");
export const OWNER_RESERVATION_LIST_SELECT = reservationListSelect("restaurants!inner(name)");
