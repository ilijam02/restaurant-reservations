# CLAUDE.md — owner app

> Status: not yet implemented. Stack decided (see root [CLAUDE.md](../CLAUDE.md)) but no code written yet.

Owner-facing application: manage staff, restaurant profile (image, name, hours, etc.), menu, restaurant sections, and the table layout used for reservations.

**Planned stack:** Next.js, calling Supabase directly (data/auth/realtime, plus Supabase Storage for restaurant images). Shares UI components and types with the other apps via `shared/`.

Once implemented, this file should document: this app's directory structure and its build/test/lint commands.
