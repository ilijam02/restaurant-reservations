// The PostgREST select string behind every reservations list (customer's own,
// an owner's per-restaurant and all-restaurants views), so they all embed the
// same shape ReservationRow describes. orders is a reverse join on
// orders.reservation_id; only confirmed orders ever carry one (set once by
// create_reservation()'s p_order_id finalization, cancelled along with the
// reservation by cancel_reservation()), so at most one per reservation in
// practice even though the FK itself isn't unique.
export const RESERVATION_LIST_SELECT =
  "id, customer_id, party_size, starts_at, ends_at, status, restaurants(name), reservation_tables(tables(name)), reservation_sections(party_size, sections(name)), orders(status, items:order_items(id, item_name, unit_price, quantity, choices:order_item_choices(option_name, choice_name, price_delta)))";
