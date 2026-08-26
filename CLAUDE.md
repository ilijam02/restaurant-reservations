# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project overview

Restaurant Reservations is a platform made of three web applications, one per user role:

- **Customer** — browse/search restaurants, view them on a map, make reservations (with optional section/table selection), place food orders alongside a reservation, pay by card, manage past/current reservations, receive status notifications.
- **Employee** — browse/search restaurants, request to join a restaurant as staff, view and update the status of customers' reservations.
- **Owner** — manage staff, restaurant profile (image, name, hours, etc.), menu, restaurant sections, and the table layout used for reservations.

All three applications share basic account features: account creation, log in/out, account deletion.

See [README.md](README.md) for the full feature list.

## Current state

This repository is in the planning stage — no application code has been written yet, but the stack is now decided.

**Repository layout (decided):** a monorepo with one directory per app — `customer/`, `employee/`, `owner/` — plus `shared/` for code and contracts used across apps (backend API/client, shared types, auth). Each of these directories has its own `CLAUDE.md` for app-specific conventions once that app is implemented; this root file stays limited to cross-cutting, repo-wide conventions. See each directory's `CLAUDE.md` for its current status.

**Tech stack (decided):**

- **Frontend:** Next.js, one app per role (`customer/`, `employee/`, `owner/`), each a thin client calling Supabase directly for data/auth/realtime. Shared UI components and TypeScript types live in `shared/`.
- **Backend/data:** [Supabase](https://supabase.com) — PostgreSQL, Supabase Auth, Supabase Realtime, and Supabase Storage (for restaurant images). Custom server-trusted logic (Stripe webhook handling, payment intent creation, reservation-slot validation, recommendation scoring) goes in Supabase Edge Functions rather than a hand-rolled backend service.
- **Authorization:** Postgres Row-Level Security (RLS) policies keyed off a role claim (customer/employee/owner), rather than app-level permission checks — this also gates Realtime subscriptions automatically.
- **Database integrity:** a Postgres exclusion constraint on table/time-range prevents double-booking at the DB level.
- **Payments:** Stripe.
- **Maps:** not yet decided — Mapbox vs. Google Places is still open.
- **Future ML recommendations:** deferred, but the schema should accommodate `pgvector` for embedding-based similarity/ranking when built.
- **Monorepo tooling:** Turborepo or pnpm workspaces (not yet finalized).

Not yet decided / still needed before implementation starts:

- Maps provider (Mapbox vs. Google Places)
- Monorepo build tooling specifics
- Build, test, and lint commands for each app
- Local dev setup (env vars, Supabase project setup, seed data)

## Working conventions

- Do not assume a specific framework or library until it's been chosen and documented here — ask rather than guessing when starting new implementation work.
- Reservations, orders, payments, and account deletion touch real user data and money — treat schema/API changes in these areas carefully and flag anything with financial or destructive implications (e.g. payment handling, cascading deletes) before implementing.
- Keep the three applications' concerns separated (customer-facing, employee-facing, owner-facing) even if they end up sharing a backend — avoid leaking role-specific logic across apps.
