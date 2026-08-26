# CLAUDE.md — customer app

> Status: not yet implemented. Stack decided (see root [CLAUDE.md](../CLAUDE.md)) but no code written yet.

Customer-facing application: browse/search restaurants, view them on a map, make reservations (with optional section/table selection), place food orders alongside a reservation, pay by card, manage past/current reservations, receive status notifications.

**Planned stack:** Next.js, calling Supabase directly (data/auth/realtime) plus Stripe for payments. Shares UI components and types with the other apps via `shared/`.

Once implemented, this file should document: this app's directory structure and its build/test/lint commands.
