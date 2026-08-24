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

This repository is in the planning stage — no application code, framework, or architecture has been chosen yet. When implementation begins, update this file with:

- the chosen tech stack per application (frontend framework, backend, database)
- repository layout (monorepo vs. separate apps/services) and where each app lives
- how the three apps share code/data (shared API, shared types, auth, payments)
- build, test, and lint commands for each app
- local dev setup (env vars, services required, seed data)

## Working conventions

- Do not assume a specific framework or library until it's been chosen and documented here — ask rather than guessing when starting new implementation work.
- Reservations, orders, payments, and account deletion touch real user data and money — treat schema/API changes in these areas carefully and flag anything with financial or destructive implications (e.g. payment handling, cascading deletes) before implementing.
- Keep the three applications' concerns separated (customer-facing, employee-facing, owner-facing) even if they end up sharing a backend — avoid leaking role-specific logic across apps.
