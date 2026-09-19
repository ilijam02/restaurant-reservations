-- Lets accepted staff step a reservation back one stage before the guest is
-- seated (ISSUES.md: "Undo a reservation status change after a misclick" -
-- the cheap part): order_prepared -> preparing_order -> confirmed.
--
-- Status label only. Neither transition touches starts_at/ends_at or
-- reservation_tables - all three statuses are "active" and sit on the same
-- time range, so there is nothing to re-check (no exclusion violation, no
-- capacity re-check). That's exactly why only these two steps are offered:
-- undoing ongoing/completed/no_show would have to reverse the starts_at/
-- ends_at rewrites those transitions make, which is the still-open "harder
-- part" of the same backlog item.
--
-- One step at a time, matching the forward graph: order_prepared cannot jump
-- straight back to confirmed. A reservation with no order never leaves
-- confirmed before ongoing, so there is nothing to step back from there.
--
-- Everything else in the function - staff-only permission, the cancelled and
-- already-ended rejections, the forward transitions - is unchanged from
-- 20260919110000_cancel_reservation_audit.sql. Only the 'preparing_order'
-- branch widened (now also from order_prepared) and a 'confirmed' branch was
-- added.

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

  if v_reservation.status = 'cancelled' then
    raise exception 'Rezervacija je otkazana.';
  end if;

  if v_reservation.ends_at <= now() then
    raise exception 'Rezervacija je već istekla.';
  end if;

  v_has_order := exists (
    select 1 from public.orders o
    where o.reservation_id = p_reservation_id and o.status = 'confirmed'
  );

  if p_new_status = 'preparing_order' then
    if v_reservation.status not in ('confirmed', 'order_prepared') or not v_has_order then
      raise exception 'Priprema porudžbine je moguća samo iz statusa "Potvrđena" ili "Porudžbina spremna" rezervacije koja ima porudžbinu.';
    end if;

  elsif p_new_status = 'confirmed' then
    if v_reservation.status <> 'preparing_order' then
      raise exception 'Rezervacija može biti vraćena na "Potvrđena" samo dok se porudžbina priprema.';
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
