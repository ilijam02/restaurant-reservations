-- Follow-ups to 20260919100000_cancel_reservation.sql (code-review):
--
-- 1. Who cancelled, and when. cancel_reservation() had no record of either,
--    and once payments exist a refund policy will need to tell a customer's
--    cancel from an owner's - which can't be reconstructed afterwards.
--    cancelled_at / cancelled_by (auth.users, set null on account deletion)
--    are nullable and only ever written by cancel_reservation(); the role is
--    derivable (cancelled_by = customer_id means the customer, anything else
--    is the restaurant's owner). Reservations cancelled before this
--    migration simply have both null. Deliberately no "status = 'cancelled'
--    iff cancelled_at is not null" check, for the same reason.
--
-- 2. update_reservation_status() on a cancelled reservation. Staff looking
--    at a stale employee page (it's a server fetch with no realtime) can
--    still click a button on a reservation that has since been cancelled;
--    the call used to fail with whichever transition message applied
--    (e.g. the "preparing_order only from Potvrđena" one), which reads as if
--    the reservation were merely in the wrong state. It now says it's
--    cancelled. Otherwise the function is unchanged from
--    20260918130000_reservation_lifecycle_review_fixes.sql.

alter table public.reservations
  add column cancelled_at timestamptz,
  add column cancelled_by uuid references auth.users (id) on delete set null;

-- Foreign key on a "set null" delete path - without an index, deleting an
-- auth user would seq-scan reservations to find rows to null out.
create index reservations_cancelled_by_idx on public.reservations (cancelled_by) where cancelled_by is not null;

create or replace function public.cancel_reservation(p_reservation_id uuid)
returns public.reservations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.reservations;
begin
  select res.* into v_reservation
  from public.reservations res
  where res.id = p_reservation_id
    and (
      res.customer_id = auth.uid()
      or exists (
        select 1 from public.restaurants r
        where r.id = res.restaurant_id and r.owner_id = auth.uid()
      )
    )
  for update;

  if not found then
    raise exception 'Rezervacija ne postoji.';
  end if;

  if v_reservation.status not in ('confirmed', 'preparing_order', 'order_prepared') then
    raise exception 'Rezervacija može biti otkazana samo dok je potvrđena ili se porudžbina priprema.';
  end if;

  -- Between ends_at and the next pg_cron sweep (up to a minute) an expired
  -- reservation still carries its old status; without this it could be
  -- cancelled just before the sweep records it as a no-show.
  if v_reservation.ends_at <= now() then
    raise exception 'Rezervacija je već istekla.';
  end if;

  update public.reservations
  set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
  where id = p_reservation_id;

  update public.reservation_tables
  set starts_at = now(), ends_at = now()
  where reservation_id = p_reservation_id;

  update public.orders
  set status = 'cancelled'
  where reservation_id = p_reservation_id and status = 'confirmed';

  select * into v_reservation from public.reservations where id = p_reservation_id;
  return v_reservation;
end;
$$;

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
