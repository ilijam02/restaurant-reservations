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
- Do not create or merge pull requests without the user's explicit permission each time — committing to a branch and opening a PR for review is fine, but ask before opening it and before merging it.
- Before changing any files for a task, create/checkout a dedicated feature branch first — never commit work directly on `main`. If the working tree already has unrelated uncommitted changes when starting (e.g. from a concurrent session in the same checkout), stash them (`git stash -u`) rather than letting them silently carry onto the new branch — otherwise they can end up committed into the wrong PR (this happened once: an in-progress dark-mode fix got swept into an unrelated `ISSUES.md` PR because it was still uncommitted when that branch was created off of it).

## Design conventions

Tailwind CSS v4. `globals.css` defines theme-aware CSS variables (`--background`/`--foreground`) that flip under `@media (prefers-color-scheme: dark)` — but that flip only covers `body`. **Every element with a hardcoded color utility must pair it with a `dark:` counterpart, or it silently breaks when the OS theme flips** — a CSS variable at the root does not propagate into hardcoded Tailwind utility classes like `bg-black` or `border-black/20`. (This exact bug shipped in the first version of the auth pages: a pure-black button and a near-invisible input border on a near-black dark-mode page, contrast ratio near 1:1.) Tailwind v4 drives `dark:` off `prefers-color-scheme` automatically, no config needed; there's no manual theme toggle in this app, so v4's class-based `@custom-variant dark` override isn't needed unless one gets added later.

- `color-scheme: light` / `color-scheme: dark` is set in `globals.css` alongside the existing variable flip, so native browser-drawn form chrome (autofill, scrollbars, default focus outline) matches the theme too.
- **Inputs/selects:** explicit background, border, and text color in both themes, plus a visible focus ring — `bg-white dark:bg-neutral-900`, `border-neutral-300 dark:border-neutral-700`, `text-neutral-900 dark:text-neutral-100`, `focus:outline-hidden focus:ring-2 focus:ring-accent`. Keep input font size at `text-base` (16px) minimum — smaller triggers iOS Safari's auto-zoom on focus.
- **Primary buttons:** `bg-accent text-accent-foreground hover:opacity-90 active:opacity-80`, plus `focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-accent dark:focus-visible:ring-offset-neutral-900` (the ring-offset color must flip per theme, or the ring gets a light halo in dark mode). Surface-level neutrals (cards, borders, plain text) still use explicit `dark:` pairs per element as above; the semantic/brand tokens below use CSS variables instead specifically *because* they're the same concept in both themes with just a different value, so there's nothing to "forget" to pair.
- **Error text:** `text-red-600 dark:text-red-400` (a saturated red reads poorly on dark surfaces) plus `role="alert"` so it's announced to screen readers. (Not `text-danger` — that token is for reservation/order status, not form validation; keep them visually distinct.)
- **Forms:** wrap in a card surface (`rounded-lg border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900 p-8 shadow-sm`) rather than floating directly on the page background — this also structurally prevents the disappearing-button bug, since the card is a distinct surface color from the page.
- **Accessibility baseline:** WCAG AA — 4.5:1 contrast for text, 3:1 for large text and non-text UI components (this covers input borders and focus rings, not just text). Never strip the default focus outline (`outline-none`/`outline-hidden`) without supplying a replacement ring. Keep `<label htmlFor>` + matching input `id` (already the pattern here) rather than placeholder-only fields.

### Color palette

Researched against comparable apps (OpenTable, Resy, Wolt, Glovo, DoorDash, Uber Eats, Airbnb, Toast, Square) — the consistent pattern is one dominant brand accent plus small semantic status colors, not a multi-color system, and business/dashboard-facing screens stay more neutral than consumer-facing ones.

- **Brand accent:** warm orange, chosen over red so it doesn't visually compete with the "cancelled" status color. Defined in `globals.css` as CSS variables (`--accent` / `--accent-foreground`) mapped through `@theme inline`, so `bg-accent`, `text-accent`, `border-accent`, `ring-accent`, `text-accent-foreground` etc. are available as plain Tailwind utility classes that automatically respond to the OS theme — no `dark:` variant needed at the call site. Light: `--accent: #c2410c` (orange-700, not orange-600 — needed for AA contrast as a white-text button fill, not just as text) with `--accent-foreground: #ffffff`. Dark: `--accent: #fb923c` (orange-400) with `--accent-foreground: #171717` (dark text on the lighter fill, not white).
- **Semantic status colors** (for reservation/order states — not built yet, tokens are ready for when they are): `--success` (green-600/green-400), `--warning` (amber-500/amber-400), `--danger` (red-600/red-400), same CSS-variable/`@theme inline` pattern. Status must never be color-only — pair with a label/icon (WCAG 1.4.1), since orange (brand) sits close to both amber (pending) and red (cancelled/danger) on the hue wheel.
- **Usage density by role:** customer-facing screens (browse/book/order) can use the accent generously — cards, map pins, hero elements, primary CTAs. Owner/employee dashboard screens (staff, menu, table layout, reservation queues) keep the existing neutral-dominant surfaces and restrict the accent to primary actions and active/selected states only, not backgrounds — same pattern Toast/Square use for their dashboards, since large saturated fields cause fatigue on screens used for long repetitive sessions.
