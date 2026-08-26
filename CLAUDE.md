# CLAUDE.md

@AGENTS.md

Guidance for Claude Code when working in this repository. (`AGENTS.md`, imported above, is auto-generated/refreshed by `next dev` with Next.js-version-specific agent warnings — leave it in place and let it regenerate rather than hand-editing it.)

## Project overview

Restaurant Reservations is a single web application serving three user roles:

- **Customer** — browse/search restaurants, view them on a map, make reservations (with optional section/table selection), place food orders alongside a reservation, pay by card, manage past/current reservations, receive status notifications.
- **Employee** — browse/search restaurants, request to join a restaurant as staff, view and update the status of customers' reservations.
- **Owner** — manage staff, restaurant profile (image, name, hours, etc.), menu, restaurant sections, and the table layout used for reservations.

All users share basic account features: account creation, log in/out, account deletion.

See [README.md](README.md) for the full feature list.

## Current state

Authentication (login, signup, role-based home pages) is implemented — see "Implemented features" below. Everything else is still unbuilt.

**Repository layout (decided):** a single Next.js application at the repo root — not a monorepo of separate apps. The three roles (customer/employee/owner) are organized internally as top-level route folders (`app/customer/`, `app/employee/`, `app/owner/` — plain folders, not Next.js's parenthesized "route group" convention, since each role's segment needs to appear in the URL) so role-specific code stays cleanly separated within the one app. This was a deliberate revision of an earlier "three separate apps" plan: for a pre-launch, unvalidated product, the isolation benefits of separate deployed apps (independent releases, team boundaries, blast-radius isolation) don't apply yet, while the cost (three times the setup, cross-app auth/session complexity) is immediate. These folders can be extracted into separate apps later if that separation is ever actually needed — that split is mechanical if the internal organization stays clean, whereas unifying three already-separate apps later would not be.

**Tech stack (decided):**

- **Frontend:** Next.js (single app, TypeScript, App Router), role-based route folders as described above.
- **Backend/data:** [Supabase](https://supabase.com) — PostgreSQL, Supabase Auth, Supabase Realtime, and Supabase Storage (for restaurant images). Custom server-trusted logic (Stripe webhook handling, payment intent creation, reservation-slot validation, recommendation scoring) goes in Supabase Edge Functions rather than a hand-rolled backend service.
- **Authorization:** Postgres Row-Level Security (RLS) policies keyed off a role claim (customer/employee/owner), rather than app-level permission checks — this also gates Realtime subscriptions automatically.
- **Database integrity:** a Postgres exclusion constraint on table/time-range prevents double-booking at the DB level.
- **Payments:** Stripe.
- **Maps:** not yet decided — Mapbox vs. Google Places is still open.
- **Future ML recommendations:** deferred, but the schema should accommodate `pgvector` for embedding-based similarity/ranking when built.

Not yet decided:

- Maps provider (Mapbox vs. Google Places)
- Monorepo/build tooling beyond plain npm (not needed yet at this scale)

**Implemented features:**

- Login (`/login`) and signup (`/signup`) with email/password via Supabase Auth. Signup also collects first name, last name, phone, and role (customer/employee/owner), stored in a `profiles` table populated by a DB trigger (`supabase/migrations/`).
- Role-based home pages (`/customer`, `/employee`, `/owner`) — title only + logout, gated by `src/proxy.ts` (Next.js 16 renamed `middleware` to `proxy` — see `AGENTS.md`).
- All UI text is in Serbian.

**Commands:** `npm run dev` / `npm run build` / `npm run lint` / `npm test`.

**Local dev setup:** copy `.env.example` to `.env.local` and fill in a Supabase project's URL + anon key. Two Supabase Auth settings matter for this app to work as designed: **"Confirm email" must be disabled** (Authentication → Sign In / Providers → Email) — the signup flow expects an immediate session, not an email-confirmation step — and test signup emails must use a real-looking domain (Supabase rejects `@example.com` as a known non-deliverable domain).

**Next planned step:** not yet decided — see this repo's design chat / memory for context on prior decisions.

## Working conventions

- Do not assume a specific framework or library until it's been chosen and documented here — ask rather than guessing when starting new implementation work.
- Reservations, orders, payments, and account deletion touch real user data and money — treat schema/API changes in these areas carefully and flag anything with financial or destructive implications (e.g. payment handling, cascading deletes) before implementing.
- Keep the three roles' concerns separated (customer-facing, employee-facing, owner-facing) via clean top-level route-folder boundaries, even though they share one app and one backend — avoid leaking role-specific logic across those folders.
