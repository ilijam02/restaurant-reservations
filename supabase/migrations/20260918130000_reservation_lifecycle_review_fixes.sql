-- Code-review follow-ups on the reservation status lifecycle
-- (20260917140000, 20260918100000, 20260918120000):
--
-- 1. Early start is now bounded. Marking a reservation ongoing before its
--    booked starts_at used to be allowed any time up to 24h ahead, and
--    permanently rewrote starts_at - a mistaken click on a reservation
--    days out was unrecoverable. It's now only allowed within 60 minutes of
--    the booked start (the UI also asks for confirmation). That window also
--    makes the old "ends more than 24h from now" guard unreachable, so it's
--    gone. Known, still-open gap: section-based and plain-capacity
--    reservations aren't re-checked against capacity for the newly
--    occupied stretch (tables are protected by the exclusion constraint).
-- 2. update_reservation_status() rejects any transition once ends_at has
--    passed. Between ends_at and the next pg_cron sweep (up to a minute) a
--    reservation still carried its old status; staff could otherwise move
--    it (e.g. to ongoing) just before the sweep overwrote it.
-- 3. Grants. update_reservation_status() was executable by anon/public: it
--    failed closed on the staff check, but its row lock and its
--    "doesn't exist" vs "no permission" messages made that path an id
--    oracle. restaurant_peak_reserved_capacity()/section_peak_reserved_capacity()
--    (recreated in the lifecycle migration) are security definer with no
--    caller scoping and default public execute - any signed-in user could
--    read any restaurant's/section's peak booked load. They're only ever
--    reached through triggers and other security definer functions
--    (which run as the owner), so no app role needs execute on them.
--    is_active_reservation_status() gets an explicit empty search_path
--    like every other function here.
-- 4. Partial index for the per-minute cron sweep, which filters on
--    ends_at and an active status and would otherwise seq-scan a table
--    that only grows.

create or replace function public.update_reservation_status(
  p_reservation_id uuid,
  p_new_status text
)
returns public.reservations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.reservations;
  v_has_order boolean;
  v_new_starts_at timestamptz;
  v_new_ends_at timestamptz;
begin
  select * into v_reservation from public.reservations where id = p_reservation_id for update;
  if not found then
    raise exception 'Rezervacija ne postoji.';
  end if;

  if not exists (
    select 1 from public.restaurant_staff rs
    where rs.restaurant_id = v_reservation.restaurant_id
      and rs.employee_id = auth.uid()
      and rs.status = 'accepted'
  ) then
    raise exception 'Nemate dozvolu da menjate status ove rezervacije.';
  end if;

  if v_reservation.ends_at <= now() then
    raise exception 'Rezervacija je već istekla.';
  end if;

  v_has_order := exists (
    select 1 from public.orders o
    where o.reservation_id = p_reservation_id and o.status = 'confirmed'
  );

  if p_new_status = 'preparing_order' then
    if v_reservation.status <> 'confirmed' or not v_has_order then
      raise exception 'Priprema porudžbine je moguća samo iz statusa "Potvrđena" rezervacije koja ima porudžbinu.';
    end if;

  elsif p_new_status = 'order_prepared' then
    if v_reservation.status <> 'preparing_order' then
      raise exception 'Porudžbina može biti označena kao spremna samo dok se priprema.';
    end if;

  elsif p_new_status = 'ongoing' then
    if v_reservation.status = 'confirmed' and v_has_order then
      raise exception 'Rezervacija ima porudžbinu - prvo je potrebno pripremiti je.';
    end if;
    if v_reservation.status not in ('confirmed', 'order_prepared') then
      raise exception 'Rezervacija mora biti potvrđena ili imati spremnu porudžbinu pre početka.';
    end if;

  elsif p_new_status = 'no_show' then
    if v_reservation.status not in ('confirmed', 'order_prepared') then
      raise exception 'Gost može biti označen kao odsutan samo dok se čeka na dolazak.';
    end if;
    if v_reservation.starts_at > now() then
      raise exception 'Gost može biti označen kao odsutan tek nakon početka rezervacije.';
    end if;

  elsif p_new_status = 'completed' then
    if v_reservation.status <> 'ongoing' then
      raise exception 'Rezervacija mora biti u toku pre nego što se završi.';
    end if;

  else
    raise exception 'Nepoznat ili nepodržan status: %.', p_new_status;
  end if;

  v_new_starts_at := v_reservation.starts_at;
  v_new_ends_at := v_reservation.ends_at;

  if p_new_status = 'ongoing' and v_reservation.starts_at > now() then
    if v_reservation.starts_at > now() + interval '60 minutes' then
      raise exception 'Rezervacija može biti označena kao u toku najviše 60 minuta pre zakazanog početka.';
    end if;
    v_new_starts_at := now();
  end if;

  if p_new_status in ('completed', 'no_show') then
    v_new_ends_at := least(v_reservation.ends_at, greatest(now(), v_reservation.starts_at + interval '1 second'));
  end if;

  begin
    if v_new_starts_at <> v_reservation.starts_at or v_new_ends_at <> v_reservation.ends_at then
      update public.reservation_tables
      set starts_at = v_new_starts_at, ends_at = v_new_ends_at
      where reservation_id = p_reservation_id;
    end if;

    update public.reservations
    set status = p_new_status, starts_at = v_new_starts_at, ends_at = v_new_ends_at
    where id = p_reservation_id;
  exception
    when exclusion_violation then
      raise exception 'Sto je zauzet pre početka ove rezervacije - ne može biti označena kao u toku.';
  end;

  select * into v_reservation from public.reservations where id = p_reservation_id;
  return v_reservation;
end;
$$;

revoke all on function public.update_reservation_status(uuid, text) from public, anon;
grant execute on function public.update_reservation_status(uuid, text) to authenticated;

revoke all on function public.restaurant_peak_reserved_capacity(uuid) from public, anon, authenticated;
revoke all on function public.section_peak_reserved_capacity(uuid) from public, anon, authenticated;

alter function public.is_active_reservation_status(text) set search_path = '';

create index reservations_active_ends_at_idx
  on public.reservations (ends_at)
  where status in ('confirmed', 'preparing_order', 'order_prepared', 'ongoing');
