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

This repository is in the planning stage — no application code has been written yet, but the stack and architecture are decided.

**Repository layout (decided):** a single Next.js application at the repo root — not a monorepo of separate apps. The three roles (customer/employee/owner) are organized internally as route groups (`app/(customer)/`, `app/(employee)/`, `app/(owner)/`) so role-specific code stays cleanly separated within the one app. This was a deliberate revision of an earlier "three separate apps" plan: for a pre-launch, unvalidated product, the isolation benefits of separate deployed apps (independent releases, team boundaries, blast-radius isolation) don't apply yet, while the cost (three times the setup, cross-app auth/session complexity) is immediate. Route groups can be extracted into separate apps later if that separation is ever actually needed — that split is mechanical if the internal organization stays clean, whereas unifying three already-separate apps later would not be.

**Tech stack (decided):**

- **Frontend:** Next.js (single app, TypeScript, App Router), role-based route groups as described above.
- **Backend/data:** [Supabase](https://supabase.com) — PostgreSQL, Supabase Auth, Supabase Realtime, and Supabase Storage (for restaurant images). Custom server-trusted logic (Stripe webhook handling, payment intent creation, reservation-slot validation, recommendation scoring) goes in Supabase Edge Functions rather than a hand-rolled backend service.
- **Authorization:** Postgres Row-Level Security (RLS) policies keyed off a role claim (customer/employee/owner), rather than app-level permission checks — this also gates Realtime subscriptions automatically.
- **Database integrity:** a Postgres exclusion constraint on table/time-range prevents double-booking at the DB level.
- **Payments:** Stripe.
- **Maps:** not yet decided — Mapbox vs. Google Places is still open.
- **Future ML recommendations:** deferred, but the schema should accommodate `pgvector` for embedding-based similarity/ranking when built.

Not yet decided / still needed before implementation starts:

- Maps provider (Mapbox vs. Google Places)
- Build, test, and lint commands
- Local dev setup (env vars, Supabase project setup, seed data)

**Next planned step:** authentication (login, signup, role-based home pages) — see this repo's design chat / memory for the detailed implementation plan.

## Working conventions

- Do not assume a specific framework or library until it's been chosen and documented here — ask rather than guessing when starting new implementation work.
- Reservations, orders, payments, and account deletion touch real user data and money — treat schema/API changes in these areas carefully and flag anything with financial or destructive implications (e.g. payment handling, cascading deletes) before implementing.
- Keep the three roles' concerns separated (customer-facing, employee-facing, owner-facing) via clean route-group boundaries, even though they share one app and one backend — avoid leaking role-specific logic across route groups.
