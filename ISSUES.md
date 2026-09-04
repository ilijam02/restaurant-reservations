# Issues / Backlog

Tracks *what's next*, not *how*. Sequencing happens in the planning chat; the
actual technical decisions and specs happen in the design decisions chat (see
`CLAUDE.md` for decisions already made). Once an item ships, check it off (or
move it to Done with a short note).

## Open decisions

Take these to the design decisions chat when they come up next.

- [ ] Maps provider: Mapbox vs Google Places
- [ ] Partially-reservable ("communal") tables: can a single table (e.g. a long shared table) host multiple independent, concurrent reservations up to its seat count, rather than one reservation always occupying the whole table? Ties directly into the deferred double-booking exclusion constraint design (table/time-range) — a communal table needs a capacity-sum overlap check instead of a simple no-overlap exclusion, plus real product questions (do unrelated groups actually get seated together, does seating need a buffer between adjacent reservations). Decide when the reservation/booking-validation feature itself is designed, not before — no schema impact today, `tables.seats` means the same thing either way.

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
- Restaurants table: minimal initial cut (`id`, `owner_id`, `name`, `created_at` only) — no `image`/`address`/`hours`/`description` yet, added when the feature that needs each one is built, not speculatively now. An owner can have more than one restaurant (`owner_id` is a plain indexed FK, not unique). RLS restricts restaurant creation to `profiles.role = 'owner'` accounts, but restaurant rows are viewable by any authenticated user (any role) — needed so customers/employees can browse.
- Employee applications/staff: single `restaurant_staff` table, one row per (restaurant, employee) pair with `status` = `pending` | `accepted`. No `rejected` status — a reject (owner) or cancel (employee) both just delete the pending row, and removing a staff member deletes the accepted row; this keeps the door open to re-apply later without extra status bookkeeping, and nothing in the product needs a record of past rejections. An employee can be staff at multiple restaurants (many rows). Owners manage this per restaurant at `/owner/restaurants/[id]/staff`. Added a narrow `profiles` RLS policy so owners can see the name of anyone with a staff row at one of their restaurants (previously profiles were self-view only).
- Restaurant capacity/hours: `capacity` (nullable int, no cap by default) and `default_stay_minutes` (not null, defaults to 90) added directly to `restaurants`. Working hours are a separate `restaurant_hours` table, one row per day of week (`day_of_week` 0-6 matching Postgres's `extract(dow ...)`, open/close both null = closed that day), so the reservation feature can later join straight against a booking's date. Overnight hours (open past midnight) aren't cross-validated yet — deferred until a restaurant actually needs it. Owner edits all of this (name, capacity, default stay time, per-day hours with an "apply Monday to all" action) at `/owner/restaurants/[id]`.
- Restaurant sections & table layout — structure: two fully independent, optional features; a restaurant can have sections, a table layout, both, or neither. A table optionally belongs to one section via `tables.section_id`, which stays nullable at the DB level even once sections exist — the rule "every table must belong to a section once the restaurant has any" is enforced entirely in app logic (Server Action + UI flow), never a DB constraint, and never leaves an inconsistent state written to the database (when the owner creates their first section, the app forces them to assign every existing table to some section as one in-app step before anything is written; every table added afterward must likewise be assigned a section at creation time whenever the restaurant already has ≥1 section). Deliberately no auto-created "default"/catch-all section — if the owner wants an "everything else" grouping they create it themselves like any other section. "Sections can't logically overlap" (e.g. indoor vs. window-seating both describing the same tables) is owner-facing UX guidance only, not something the system validates — a table can reference at most one section by construction, so true overlap can't occur in the data. The table layout builder is spatial (a floor-plan canvas with positioned tables), not a plain list; the position/shape data format is deferred until the layout editor itself is built. RLS will follow the existing `restaurant_hours` pattern (owner-scoped write, any-authenticated-user read).
- Restaurant sections & table layout — capacity cascade: "more specific overrides broader." No sections and no layout: `restaurants.capacity` stays exactly as today (manually typed, nullable, no cap by default). Sections exist, no layout: each section has its own manually-typed capacity; `restaurants.capacity` becomes derived (`sum` of section capacities) from the first section onward — the owner's edit form shows this live as sections are added/edited/removed, before saving. A table layout exists: capacity fully derives from tables — a section's capacity = sum of its tables' seats, `restaurants.capacity` = sum of every table's seats, nothing manually typed at this level (not built yet). Deleting things hands capacity back to the next most-specific surviving source: deleting the last section (no layout) unfreezes `restaurants.capacity` to manual, seeded at its last derived value; deleting a layout unfreezes any surviving sections to manual (seeded at their last derived sums) and hands `restaurants.capacity` to a live `sum(sections)` if any sections survive, or unfreezes it to manual (seeded from its last table-derived value) only if none do either.
- Restaurant sections — implementation (sections-only pass, no table layout yet): `sections` table (`restaurant_id`, `name`, `capacity`, unique name per restaurant), owner-write/any-authenticated-read RLS matching `restaurant_hours`. Section management lives inside the same "Uredi restoran" form as name/hours/capacity at `/owner/restaurants/[id]/edit` (not a separate page) — sections are staged locally (`SectionsEditor`, a controlled component like `RestaurantHoursCalendar`) and only written to the database together with everything else on one "Sačuvaj izmene" submit, which reconciles inserts/updates/deletes by diffing the draft against the sections that were loaded. Because sections can only be mutated through this single save point, `restaurants.capacity` is simply recomputed and written on every save (the effective value — derived sum or manual number — rather than left stale and computed separately on every read elsewhere), which is a simpler realization of the "computed, nothing trigger-maintained" principle than originally planned.

## Done

- [x] Auth: login/signup, role-based home pages (`/customer`, `/employee`, `/owner`)
- [x] Owner: create a restaurant (name only) and see own restaurant list
- [x] Customer/employee: browse and search (by name, client-side) the full restaurant list, unranked
- [x] Employee: apply to a restaurant as staff, cancel a pending application
- [x] Owner: view active applications and staff per restaurant, accept/reject applications, remove staff
- [x] Owner: edit restaurant details (name, capacity, default stay time, per-day working hours)
- [x] Owner: manage restaurant sections (name, capacity) from the same restaurant edit page; no table layout yet, so capacity is fully derived from sections once any exist

## Backlog

### Shared

- [ ] Account deletion

### Customer

- [ ] Rank browsed restaurants by ML recommendation algorithm (schema should accommodate pgvector; scoring itself is deferred)
- [ ] View restaurants on a map
- [ ] Make a reservation (time, party size; optional section/table selection)
- [ ] Place an order alongside a reservation
- [ ] Pay by debit card (Stripe)
- [ ] Cancel a reservation
- [ ] View past reservations
- [ ] View current reservations
- [ ] Reservation/order status notifications

### Employee

- [ ] View customers' current reservations
- [ ] Update the status of customers' reservations

### Owner

- [ ] Add restaurant image/description (remaining profile fields; name/capacity/hours already editable)
- [ ] Delete a restaurant
- [ ] Manage menu items (add/change/remove)
- [ ] Create/edit the table layout
