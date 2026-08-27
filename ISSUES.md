# Issues / Backlog

Tracks *what's next*, not *how*. Sequencing happens in the planning chat; the
actual technical decisions and specs happen in the design decisions chat (see
`CLAUDE.md` for decisions already made). Once an item ships, check it off (or
move it to Done with a short note).

## Open decisions

Take these to the design decisions chat when they come up next.

- [ ] Maps provider: Mapbox vs Google Places

## Done

- [x] Auth: login/signup, role-based home pages (`/customer`, `/employee`, `/owner`)

## Backlog

### Shared

- [ ] Account deletion

### Customer

- [ ] Browse restaurants, ranked by ML recommendation algorithm (schema should accommodate pgvector; scoring itself is deferred)
- [ ] Search for restaurants
- [ ] View restaurants on a map
- [ ] Make a reservation (time, party size; optional section/table selection)
- [ ] Place an order alongside a reservation
- [ ] Pay by debit card (Stripe)
- [ ] Cancel a reservation
- [ ] View past reservations
- [ ] View current reservations
- [ ] Reservation/order status notifications

### Employee

- [ ] Browse/search restaurants
- [ ] Request to join a restaurant as staff
- [ ] View customers' current reservations
- [ ] Update the status of customers' reservations

### Owner

- [ ] Add/remove employees
- [ ] Manage restaurant profile (image, name, hours, other attributes)
- [ ] Manage menu items (add/change/remove)
- [ ] Manage restaurant sections
- [ ] Create/edit the table layout
