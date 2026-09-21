-- Code-review follow-ups to 20260920160000_order_payments.sql.
--
-- 1. mark_order_paid() no longer insists on "the order's current session".
--    That rule meant a payment on a session that had been replaced (two tabs
--    both clicking "Plati", or expire() losing a race with a payment) was
--    silently dropped: the customer was charged, the order stayed unpaid, and
--    nothing refunded it. The webhook is signed and the session is one this app
--    created for that order (order id in its metadata), so the payment is
--    accepted whichever session made it; what matters is the order's state:
--      unpaid + confirmed  -> paid (records the paying session/intent)
--      unpaid + cancelled  -> refund_pending (as before)
--      anything else       -> 'duplicate': the order was already paid by a
--                             different payment - the caller refunds this one
--    A replay of the payment already recorded (same PaymentIntent) is a no-op
--    that returns the current state, as before. A missing order returns null,
--    which the caller also refunds (money taken, nothing to attach it to).
--
-- 2. cancel_reservation(): v_by_customer was null when customer_id is null
--    (an anonymized booking), which made the refund CASE skip. Only the
--    restaurant's owner can cancel such a booking, so null now means "not the
--    customer" and the owner-always-refunds rule applies.
--
-- 3. A refund that is queued but not yet sent (refund_pending) can only be
--    retried by someone who can still see the order. Deleting the account (or
--    the restaurant) that owns that visibility would strand the money, so both
--    deletions are refused while a refund is pending - with a message telling
--    the user how to finish it (the retry button on the reservations list).
--    delete_my_account() reaches the owner's side through delete_restaurant(),
--    so the guard lives in that one place for restaurants. Otherwise both
--    functions are unchanged.

create or replace function public.mark_order_paid(p_order_id uuid, p_session_id text, p_payment_intent_id text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;

  if not found then
    return null;
  end if;

  -- Replay of the payment already recorded on this order.
  if v_order.payment_status <> 'unpaid'
     and p_payment_intent_id is not null
     and v_order.stripe_payment_intent_id = p_payment_intent_id then
    return v_order.payment_status;
  end if;

  -- Already paid (or refunded) by a different payment: this one is a duplicate.
  if v_order.payment_status <> 'unpaid' then
    return 'duplicate';
  end if;

  if v_order.status = 'confirmed' then
    update public.orders
    set payment_status = 'paid', paid_at = now(),
        stripe_checkout_session_id = p_session_id, stripe_payment_intent_id = p_payment_intent_id
    where id = p_order_id;
    return 'paid';
  elsif v_order.status = 'cancelled' then
    update public.orders
    set payment_status = 'refund_pending', paid_at = now(),
        stripe_checkout_session_id = p_session_id, stripe_payment_intent_id = p_payment_intent_id
    where id = p_order_id;
    return 'refund_pending';
  end if;

  -- A draft can't have a payable session; if money arrived anyway, give it back.
  return 'duplicate';
end;
$$;

create or replace function public.cancel_reservation(p_reservation_id uuid)
returns public.reservations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.reservations;
  v_by_customer boolean;
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

  -- coalesce: an anonymized booking (customer_id null) can only be cancelled
  -- by the owner, so "not the customer".
  v_by_customer := coalesce(v_reservation.customer_id = auth.uid(), false);

  update public.reservations
  set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
  where id = p_reservation_id;

  update public.reservation_tables
  set starts_at = now(), ends_at = now()
  where reservation_id = p_reservation_id;

  update public.orders
  set status = 'cancelled',
      payment_status = case
        when payment_status = 'paid' and (not v_by_customer or v_reservation.status = 'confirmed')
          then 'refund_pending'
        else payment_status
      end
  where reservation_id = p_reservation_id and status = 'confirmed';

  select * into v_reservation from public.reservations where id = p_reservation_id;
  return v_reservation;
end;
$$;

create or replace function public.delete_restaurant(p_restaurant_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1
  from public.restaurants
  where id = p_restaurant_id and owner_id = auth.uid() and archived_at is null
  for update;

  if not found then
    raise exception 'Restoran ne postoji.';
  end if;

  if exists (
    select 1 from public.reservations res
    where res.restaurant_id = p_restaurant_id
      and public.is_active_reservation_status(res.status)
      and res.ends_at > now()
  ) then
    raise exception 'Restoran ima aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.';
  end if;

  if exists (
    select 1 from public.orders o
    where o.restaurant_id = p_restaurant_id and o.payment_status = 'refund_pending'
  ) then
    raise exception 'Restoran ima povraćaje novca koji su u toku. Završite ih (dugme "Ponovi povraćaj novca" na listi rezervacija), pa pokušajte ponovo.';
  end if;

  if exists (select 1 from public.reservations where restaurant_id = p_restaurant_id) then
    update public.restaurants set archived_at = now() where id = p_restaurant_id;
    delete from public.restaurant_staff where restaurant_id = p_restaurant_id;
    delete from public.orders where restaurant_id = p_restaurant_id and status = 'draft';
    return 'archived';
  end if;

  delete from public.restaurants where id = p_restaurant_id;
  return 'deleted';
end;
$$;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_blocking_name text;
  v_restaurant_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Nalog ne postoji.';
  end if;

  perform 1 from auth.users where id = auth.uid() for update;
  if not found then
    raise exception 'Nalog ne postoji.';
  end if;

  if exists (
    select 1 from public.reservations res
    where res.customer_id = auth.uid()
      and public.is_active_reservation_status(res.status)
      and res.ends_at > now()
  ) then
    raise exception 'Imate aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.';
  end if;

  -- The account is what lets this user see (and so retry) their own refund.
  if exists (
    select 1 from public.orders o
    where o.customer_id = auth.uid() and o.payment_status = 'refund_pending'
  ) then
    raise exception 'Imate povraćaj novca koji je u toku. Završite ga (dugme "Ponovi povraćaj novca" na listi rezervacija), pa pokušajte ponovo.';
  end if;

  select r.name into v_blocking_name
  from public.restaurants r
  where r.owner_id = auth.uid()
    and r.archived_at is null
    and exists (
      select 1 from public.reservations res
      where res.restaurant_id = r.id
        and public.is_active_reservation_status(res.status)
        and res.ends_at > now()
    )
  order by r.name
  limit 1;
  if found then
    raise exception 'Restoran „%” ima aktivne rezervacije. Otkažite ih ili sačekajte da se završe, pa pokušajte ponovo.', v_blocking_name;
  end if;

  for v_restaurant_id in
    select id from public.restaurants
    where owner_id = auth.uid() and archived_at is null
  loop
    perform public.delete_restaurant(v_restaurant_id);
  end loop;

  delete from public.orders where customer_id = auth.uid() and status = 'draft';

  delete from auth.users where id = auth.uid();
end;
$$;
