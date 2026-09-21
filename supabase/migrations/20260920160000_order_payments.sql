-- Card payment for a confirmed order (ISSUES.md: "Pay by debit card"). Stripe
-- test mode only - a demo, no real money; every dinar of a payment goes to one
-- platform Stripe account (no marketplace split).
--
-- The payment itself lives in Stripe; the database only tracks its state on
-- the order, and never trusts the client for it. Same pattern as reservations
-- and orders generally: authenticated has select only, so payment_status and
-- the Stripe ids can't be written from the browser at all. They're written
-- by the three functions below, executable by service_role only - i.e. by
-- the create-checkout / stripe-webhook / refund-order Edge Functions - and by
-- cancel_reservation() when it queues a refund.
--
-- payment_status:
--   unpaid          default; also every order that predates payments
--   paid            Checkout completed (stripe-webhook -> mark_order_paid)
--   refund_pending  paid, and the cancellation rules say the money goes back;
--                   set by cancel_reservation(), or by mark_order_paid() when
--                   the payment lands after the order was already cancelled
--   refunded        the refund-order function got Stripe to refund it
--
-- Refund policy (decided with the user): the restaurant's owner cancelling
-- always refunds; a customer cancelling refunds only while the reservation is
-- still 'confirmed' - once the kitchen has started (preparing_order /
-- order_prepared) the customer's cancellation keeps the payment.

alter table public.orders
  add column payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid', 'paid', 'refund_pending', 'refunded')),
  add column stripe_checkout_session_id text,
  add column stripe_payment_intent_id text,
  add column paid_at timestamptz,
  add column refunded_at timestamptz;

create unique index orders_stripe_checkout_session_id_idx
  on public.orders (stripe_checkout_session_id)
  where stripe_checkout_session_id is not null;

-- Called by create-checkout right after it creates a Checkout Session, so the
-- webhook can tell the session it's told about is the order's current one.
-- Only an unpaid, confirmed order can be paid for.
create function public.set_order_checkout_session(p_order_id uuid, p_session_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.orders
  set stripe_checkout_session_id = p_session_id
  where id = p_order_id and status = 'confirmed' and payment_status = 'unpaid';

  if not found then
    raise exception 'Porudžbina nije spremna za plaćanje.';
  end if;
end;
$$;

-- Called by stripe-webhook on checkout.session.completed (and by
-- create-checkout when it finds the order's previous session already paid).
-- Idempotent: Stripe retries webhooks, so a second call is a no-op returning
-- the current state. Returns null when the session isn't the order's current
-- one (a stale, expired session) so the caller can log it.
--
-- The payment can land after the order was cancelled (the customer cancelled
-- while sitting on the Stripe page): it's then recorded as refund_pending, so
-- the money goes back instead of sitting on a cancelled order.
create function public.mark_order_paid(p_order_id uuid, p_session_id text, p_payment_intent_id text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;

  if not found or v_order.stripe_checkout_session_id is distinct from p_session_id then
    return null;
  end if;

  if v_order.payment_status <> 'unpaid' then
    return v_order.payment_status;
  end if;

  if v_order.status = 'confirmed' then
    update public.orders
    set payment_status = 'paid', paid_at = now(), stripe_payment_intent_id = p_payment_intent_id
    where id = p_order_id;
    return 'paid';
  elsif v_order.status = 'cancelled' then
    update public.orders
    set payment_status = 'refund_pending', paid_at = now(), stripe_payment_intent_id = p_payment_intent_id
    where id = p_order_id;
    return 'refund_pending';
  end if;

  return v_order.payment_status;
end;
$$;

-- Called by refund-order once Stripe has accepted the refund.
create function public.mark_order_refunded(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.orders
  set payment_status = 'refunded', refunded_at = now()
  where id = p_order_id and payment_status = 'refund_pending';
end;
$$;

revoke all on function public.set_order_checkout_session(uuid, text) from public, anon, authenticated;
revoke all on function public.mark_order_paid(uuid, text, text) from public, anon, authenticated;
revoke all on function public.mark_order_refunded(uuid) from public, anon, authenticated;
grant execute on function public.set_order_checkout_session(uuid, text) to service_role;
grant execute on function public.mark_order_paid(uuid, text, text) to service_role;
grant execute on function public.mark_order_refunded(uuid) to service_role;

-- cancel_reservation() now queues the refund. Otherwise unchanged from
-- 20260919100000_cancel_reservation.sql / 20260919110000_cancel_reservation_audit.sql.
-- The decision is made here, in the same transaction and off the status the
-- row had under the lock, so it can't race a kitchen status change; the actual
-- Stripe refund happens afterwards (refund-order), which is why the state is
-- 'refund_pending' rather than 'refunded'.
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

  v_by_customer := v_reservation.customer_id = auth.uid();

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

revoke all on function public.cancel_reservation(uuid) from public, anon;
grant execute on function public.cancel_reservation(uuid) to authenticated;
