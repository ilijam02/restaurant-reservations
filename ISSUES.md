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
- Restaurants table: minimal initial cut (`id`, `owner_id`, `name`, `created_at` only) — no `image`/`address`/`hours`/`description` yet, added when the feature that needs each one is built, not speculatively now. An owner can have more than one restaurant (`owner_id` is a plain indexed FK, not unique). RLS restricts restaurant creation to `profiles.role = 'owner'` accounts, but restaurant rows are viewable by any authenticated user (any role) — needed so customers/employees can browse. No sections/tables/layout yet — deferred until the reservation-layout feature is actually built.
- Employee applications/staff: single `restaurant_staff` table, one row per (restaurant, employee) pair with `status` = `pending` | `accepted`. No `rejected` status — a reject (owner) or cancel (employee) both just delete the pending row, and removing a staff member deletes the accepted row; this keeps the door open to re-apply later without extra status bookkeeping, and nothing in the product needs a record of past rejections. An employee can be staff at multiple restaurants (many rows). Owners manage this per restaurant at `/owner/restaurants/[id]/staff`. Added a narrow `profiles` RLS policy so owners can see the name of anyone with a staff row at one of their restaurants (previously profiles were self-view only).

## Done

- [x] Auth: login/signup, role-based home pages (`/customer`, `/employee`, `/owner`)
- [x] Owner: create a restaurant (name only) and see own restaurant list
- [x] Customer/employee: browse and search (by name, client-side) the full restaurant list, unranked
- [x] Employee: apply to a restaurant as staff, cancel a pending application
- [x] Owner: view active applications and staff per restaurant, accept/reject applications, remove staff

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

- [ ] Manage restaurant profile (image, hours, other attributes; edit/delete)
- [ ] Manage menu items (add/change/remove)
- [ ] Manage restaurant sections
- [ ] Create/edit the table layout
