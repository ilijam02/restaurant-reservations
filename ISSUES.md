# Issues / Backlog

Tracks *what's next*, not *how*. Sequencing happens in the planning chat; the
actual technical decisions and specs happen in the design decisions chat (see
`CLAUDE.md` for decisions already made). Once an item ships, check it off (or
move it to Done with a short note).

## Open decisions

Take these to the design decisions chat when they come up next.

- [ ] Maps provider: Mapbox vs Google Places
- [ ] Restaurants table: core columns (name, address/location, hours, etc.) — initial cut, layout/sections can come later

## Decided

Already settled in the design decisions chat, documented in full in `CLAUDE.md`. Listed here for visibility, not to re-litigate.

- Repo layout: single Next.js app, role-based top-level route folders (`app/customer/`, `app/employee/`, `app/owner/`) — not separate apps per role
- Frontend: Next.js, TypeScript, App Router
- Backend/data: Supabase (Postgres, Auth, Realtime, Storage); custom trusted logic (Stripe webhooks, payment intents, slot validation, recommendation scoring) in Supabase Edge Functions
- Authorization: Postgres RLS keyed off a role claim, not app-level checks
- Double-booking prevention: Postgres exclusion constraint on table/time-range
- Payments: Stripe
- ML recommendations: deferred, but schema should accommodate `pgvector` for when it's built
- Design/color palette: warm orange accent (brighter orange-500/orange-300, dark text on fill) + warm stone neutrals (never black/near-black as a background) + semantic status colors (success/warning/danger, not yet used) — see CLAUDE.md's Design conventions section

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
