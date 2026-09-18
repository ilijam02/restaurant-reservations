-- Automatic end-of-reservation status transitions, once ends_at has passed:
--   ongoing                                       -> completed
--   confirmed / preparing_order / order_prepared  -> no_show
-- (anything still waiting on the guest when the slot ran out - whether or
-- not the kitchen had already started on their order - never showed up).
-- Staff who seat a party but forget to mark it ongoing will therefore see
-- it recorded as a no-show; deliberate, staff are expected to keep
-- statuses current.
--
-- Nothing else needs to happen alongside the status change: by the time
-- ends_at has passed the reservation's table/section capacity is already
-- free (every capacity check and the reservation_tables exclusion
-- constraint work off the time range), so unlike a *manual* early
-- no_show/completed in update_reservation_status() there is no ends_at to
-- shrink. cancelled and already-terminal reservations are left alone.
--
-- Deliberately not routed through update_reservation_status(): that RPC is
-- staff-only and validates a single transition for a signed-in caller,
-- whereas this is a system sweep. It is not callable by any app role -
-- only the function's owner, which is who pg_cron runs it as. The single
-- UPDATE re-checks the status filter after any row lock, so a staff member
-- changing a reservation at the same instant can't be overwritten with a
-- stale status.
create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.finish_expired_reservations()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.reservations
  set status = case when status = 'ongoing' then 'completed' else 'no_show' end
  where ends_at <= now()
    and status in ('confirmed', 'preparing_order', 'order_prepared', 'ongoing');
$$;

revoke all on function public.finish_expired_reservations() from public, anon, authenticated, service_role;

-- cron.schedule() with an existing job name replaces that job, so
-- re-running this migration doesn't stack duplicate schedules.
select cron.schedule(
  'finish-expired-reservations',
  '* * * * *',
  $$select public.finish_expired_reservations()$$
);
