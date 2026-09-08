# Issues / Backlog

Tracks *what's next*, not *how*. Sequencing happens in the planning chat; the
actual technical decisions and specs happen in the design decisions chat (see
`CLAUDE.md` for decisions already made). Once an item ships, check it off (or
move it to Done with a short note).

## Open decisions

Take these to the design decisions chat when they come up next.

- [ ] Maps provider: Mapbox vs Google Places

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
- Restaurant sections & table layout — structure: two fully independent, optional features; a restaurant can have sections, a table layout, both, or neither. A table optionally belongs to one section via `tables.section_id`, which stays nullable at the DB level even once sections exist — the rule "every table in an active layout must belong to a section once the restaurant has any" is enforced entirely in app logic (checked at save time against the union of active layouts' tables), never a DB constraint. Deliberately no auto-created "default"/catch-all section — if the owner wants an "everything else" grouping they create it themselves like any other section. "Sections can't logically overlap" (e.g. indoor vs. window-seating both describing the same tables) is owner-facing UX guidance only, not something the system validates — a table can reference at most one section by construction, so true overlap can't occur in the data. The table layout builder is a spatial floor-plan canvas (60x40 grid, 24px/unit, snap-to-grid, pans via a shorter fixed-height scrollable viewport) with drag-to-move, resize, marquee multi-select, and bulk section-assign/delete; tables can't overlap (rejected at drag/resize/add time), and a new table inherits the previous one's section and size. Table names are *not* unique (unlike sections/layouts, which are, per restaurant). RLS follows the existing `restaurant_hours` pattern (owner-scoped write, any-authenticated-user read) for `sections`, `layouts`, and `tables` alike — `tables`' insert/update policies additionally verify that `layout_id`/`section_id` belong to the *same* restaurant as `restaurant_id`, not just that `restaurant_id` itself is owned by the caller: since `layouts`/`sections` ids are publicly readable (same any-authenticated-user pattern), an owner could otherwise attach their own restaurant's table to another restaurant's layout or section via a direct API call.
- Restaurant sections & table layout — capacity cascade: "more specific overrides broader," but revised from the original plan to *never overwrite* `restaurants.capacity`/`sections.capacity` except in pure manual mode (no sections, no active layout) — see the implementation note below for why. No sections and no active layout: the columns hold the plain manually-typed numbers, editable as normal. Sections exist, no active layout: each section has its own manually-typed capacity (editable input); the restaurant's total is shown live as `sum` of section capacities, computed fresh on every render — not read from `restaurants.capacity`. Any layout is active: capacity is shown live from the union of every *active* layout's tables (a restaurant can have several active at once, e.g. one per floor) — a section's live capacity = sum of its seats across all active layouts, the restaurant's live total = sum of every active layout's tables — again computed fresh, never read from the columns. Removing the last section, or deactivating/deleting the last active layout, doesn't reseed anything: the manual capacity field/section rows simply become editable again, showing whatever was last actually stored in the database (untouched the whole time it was in derived/live-only mode), not a value freshly computed from what just got removed.
- Restaurant sections & table layout — implementation: `sections` and `layouts` tables (both `restaurant_id`-scoped, `layouts` also has `is_active boolean`), `tables` scoped to a `layout_id`. Everything — name/hours/capacity, sections, layouts (create/activate/deactivate/delete), and the currently-open layout's floor-plan canvas (drag/resize/marquee-select/bulk section-assign, snap-to-grid, no overlap allowed) — lives on one page (`/owner/restaurants/[id]/edit`), staged as one shared local draft and committed together on a single "Sačuvaj izmene". A section/layout/table's local draft `key` is its own real id for anything already saved (never a fresh random id) — this is load-bearing: tables reference a section by that same key, and a random key here breaks both hydration and the live capacity math. `restaurants.capacity` and `sections.capacity` are deliberately **only written to in pure manual mode** — while sections or an active layout exist, the displayed number is always computed live from sections/tables (see the cascade note above) and those columns are left untouched, so a manually-typed number quietly survives being superseded and reappears if sections/active layouts are later removed. This means any code outside this form (e.g. a future customer-facing restaurant listing) can't just read `restaurants.capacity`/`sections.capacity` and trust it — it must compute the effective capacity itself whenever the restaurant has sections or an active layout, the same way this form does.
- Reservation booking: tables are exclusive, not communal — a table hosts one confirmed reservation per time range (the "partially-reservable tables" question this used to leave open is resolved: not for now). `create_reservation()` is a single Postgres `security definer` RPC rather than a Supabase Edge Function, since it's pure check-then-insert against the DB with no third-party API or secret involved — the restaurant row is locked unconditionally before any capacity read, serializing every booking attempt against that restaurant so concurrent capacity checks can't race, with the table-level exclusion constraint as a final backstop. Duration is capped between 30 and 180 minutes independent of restaurant hours, falling back to `restaurants.default_stay_minutes` (now constrained to that same 30-180 range) when left unspecified. Where a reservation is actually seated lives in two child tables (`reservation_tables`, `reservation_sections` — mutually exclusive per reservation, neither used in the plain-capacity baseline case) rather than a column on `reservations` itself, since one reservation can span multiple tables or multiple sections. A section preference is always just that — a preference, never a hard requirement: whether picking tables (once a layout is active) or sections (no layout), the system fills the preferred one first and spills the remainder elsewhere rather than rejecting outright; only an explicit table pick is validated strictly, with no auto-expansion. Capacity follows the existing cascade (active layout > sections > plain `restaurants.capacity`). Two further `security definer` RPCs (`get_occupied_table_ids`, `get_section_remaining_capacity`) let the customer-facing form preview live availability before submitting — without exposing whose reservation occupies what, since RLS otherwise hides other customers' bookings entirely — but that preview is informational only; every actual check still happens server-side in `create_reservation()` at submit time.

## Done

- [x] Auth: login/signup, role-based home pages (`/customer`, `/employee`, `/owner`)
- [x] Owner: create a restaurant (name only) and see own restaurant list
- [x] Customer/employee: browse and search (by name, client-side) the full restaurant list, unranked
- [x] Employee: apply to a restaurant as staff, cancel a pending application
- [x] Owner: view active applications and staff per restaurant, accept/reject applications, remove staff
- [x] Owner: edit restaurant details (name, capacity, default stay time, per-day working hours)
- [x] Owner: manage restaurant sections (name, capacity) from the same restaurant edit page
- [x] Owner: create/edit/activate multiple table layouts (floor plan canvas) from the same restaurant edit page; restaurant/section capacity derives live from all active layouts' tables
- [x] Customer: make a reservation — date/time, party size, duration; optional table pick (visual floor-plan picker with live free/occupied preview) or section preference, both just preferences with automatic assignment/spillover otherwise (see the Decided note above)

## Backlog

### Shared

- [ ] Account deletion

### Customer

- [ ] Rank browsed restaurants by ML recommendation algorithm (schema should accommodate pgvector; scoring itself is deferred)
- [ ] View restaurants on a map
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
