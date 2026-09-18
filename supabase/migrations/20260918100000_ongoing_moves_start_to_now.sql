-- Follow-up to 20260917140000_reservation_status_lifecycle.sql: confirmed/
-- order_prepared -> ongoing has no timing gate (staff may seat a party
-- early), and previously left starts_at untouched. That made an early
-- "completed" awkward - ends_at was clamped to starts_at + 1 second, i.e. a
-- reservation that "ended" in the future - and let a reservation be
-- ongoing while its own starts_at was still ahead of now().
--
-- Now, marking a reservation ongoing before its booked starts_at moves
-- starts_at to now() (on reservations and, for the exclusion constraint's
-- sake, its reservation_tables rows), so an ongoing reservation has always
-- genuinely started and a later early completion's ends_at = now() is
-- always after starts_at.
--
-- Two consequences of pulling starts_at earlier, both handled explicitly:
-- 1. The occupied range grows backwards from [starts_at, ends_at) to
--    [now(), ends_at). Another reservation may already hold one of its
--    tables in that gap - the reservation_tables exclusion constraint
--    rejects the update, surfaced here as a readable message instead of a
--    raw constraint error. (Section-based and plain-capacity reservations
--    have no such constraint - see the note in ISSUES.md about that gap.)
-- 2. reservations.ends_at is capped at starts_at + 24 hours by a check
--    constraint. A reservation booked far enough ahead would violate it
--    once starts_at moves to now(), so that case is rejected up front with
--    a clear message rather than a raw check_violation.
--
-- The "completed"/"no_show" ends_at clamp (never at or before starts_at)
-- stays as a cheap guard: pgTAP runs a whole file in one transaction where
-- now() doesn't advance, and ongoing -> completed within the same instant
-- would otherwise produce ends_at = starts_at.
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
    if v_reservation.ends_at > now() + interval '24 hours' then
      raise exception 'Rezervacija počinje za više od 24 sata i ne može biti označena kao u toku.';
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
