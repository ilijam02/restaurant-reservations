-- Pay first, book after: a reservation with an order is created only once its
-- payment has succeeded. Until then the booking request is just data on the
-- customer's draft order; a failed, abandoned or refused payment leaves no
-- reservation behind.
--
-- Flow:
--   1. create-checkout dry-runs the booking (validate_booking) so an obviously
--      impossible request - closed, full, table taken - is refused before any
--      payment, then opens a Stripe Checkout Session and stores the booking
--      request and the expected total on the draft order
--      (set_order_pending_booking).
--   2. On checkout.session.completed the webhook calls finalize_paid_booking(),
--      which re-checks the cart total against the expected one and runs the real
--      create_reservation() for the customer, in one transaction with marking
--      the order paid.
--   3. If the booking can't be made after all (the slot was taken while the
--      customer paid, the time passed, the cart was edited on the Stripe page),
--      finalize_paid_booking() records why on the draft order and reports
--      'failed'; the webhook then refunds the payment. No reservation exists.
--
-- Nothing holds the slot while the customer is on the Stripe page - the
-- exclusion constraint / capacity checks run at step 2 - so step 3 is the price
-- of "no reservation until paid": the customer is refunded automatically and told.
--
-- This replaces "book first, pay the confirmed order" from
-- 20260920160000_order_payments.sql, so mark_order_paid() and
-- set_order_checkout_session() are gone. cancel_reservation()'s refund policy,
-- mark_order_refunded() and the payment_status values are unchanged.

alter table public.orders
  add column pending_booking jsonb,
  add column checkout_total_para bigint,
  add column booking_failure text;

drop function public.mark_order_paid(uuid, text, text);
drop function public.set_order_checkout_session(uuid, text);

-- Dry run of create_reservation(): same arguments, same validation and errors,
-- and nothing is kept. The inner block is rolled back by raising a private
-- sentinel error (SQLSTATE BK001) that is caught here; any real validation error
-- from create_reservation() propagates untouched (its messages are Serbian and
-- user-facing). It runs as the caller, so create_reservation()'s own ownership
-- checks apply.
create function public.validate_booking(
  p_restaurant_id uuid,
  p_party_size integer,
  p_starts_at timestamptz,
  p_stay_minutes integer default null,
  p_section_id uuid default null,
  p_table_ids uuid[] default null,
  p_order_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.create_reservation(
      p_restaurant_id, p_party_size, p_starts_at, p_stay_minutes, p_section_id, p_table_ids, p_order_id
    );
    raise exception 'dry run' using errcode = 'BK001';
  exception
    when sqlstate 'BK001' then
      null;
  end;
end;
$$;

revoke all on function public.validate_booking(uuid, integer, timestamptz, integer, uuid, uuid[], uuid) from public, anon;
grant execute on function public.validate_booking(uuid, integer, timestamptz, integer, uuid, uuid[], uuid) to authenticated;

-- Called by create-checkout after it creates a Checkout Session: remember what
-- is being paid for. Only a draft, unpaid order can be. The total is what the
-- Checkout Session was priced from; finalize_paid_booking() refuses to book if
-- the cart no longer adds up to it.
create function public.set_order_pending_booking(
  p_order_id uuid,
  p_session_id text,
  p_booking jsonb,
  p_total_para bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.orders
  set pending_booking = p_booking,
      checkout_total_para = p_total_para,
      stripe_checkout_session_id = p_session_id,
      booking_failure = null
  where id = p_order_id and status = 'draft' and payment_status = 'unpaid';

  if not found then
    raise exception 'Porudžbina nije spremna za plaćanje.';
  end if;
end;
$$;

-- Called by stripe-webhook on checkout.session.completed. Returns:
--   'booked'  the reservation was created and the order is paid
--   'replay'  this payment was already recorded (Stripe retries webhooks)
--   'failed'  the booking couldn't be made; why is stored in booking_failure.
--             The caller refunds the payment.
--   'stray'   nothing is waiting for this payment - the order is missing, was
--             already booked by another payment, or has no pending booking. The
--             caller refunds the payment.
-- Any Checkout Session of an awaiting order is accepted, not just the latest one:
-- a customer who opened two tabs and paid the older one is still paying for the
-- same booking (the later one then comes back 'stray' and is refunded).
--
-- The customer is impersonated only for the create_reservation() call, by
-- setting the transaction-local JWT claims that auth.uid() reads, so every
-- check in create_reservation() (role, restaurant, hours, capacity, tables,
-- cart) applies exactly as if the customer had booked - and the previous
-- claims are restored afterwards.
create function public.finalize_paid_booking(p_order_id uuid, p_session_id text, p_payment_intent_id text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_booking jsonb;
  v_total bigint;
  v_previous_claims text;
  v_message text;
begin
  select * into v_order from public.orders where id = p_order_id for update;

  if not found then
    return 'stray';
  end if;

  if v_order.payment_status <> 'unpaid'
     and p_payment_intent_id is not null
     and v_order.stripe_payment_intent_id = p_payment_intent_id then
    return 'replay';
  end if;

  if v_order.status <> 'draft' or v_order.pending_booking is null then
    return 'stray';
  end if;

  v_booking := v_order.pending_booking;

  select coalesce(sum(round(oi.unit_price * 100)::bigint * oi.quantity), 0)
  into v_total
  from public.order_items oi
  where oi.order_id = p_order_id;

  if v_total is distinct from v_order.checkout_total_para then
    update public.orders
    set pending_booking = null, checkout_total_para = null, stripe_checkout_session_id = null,
        booking_failure = 'Porudžbina je izmenjena tokom plaćanja.'
    where id = p_order_id;
    return 'failed';
  end if;

  v_previous_claims := current_setting('request.jwt.claims', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_order.customer_id, 'role', 'authenticated')::text,
    true
  );

  begin
    perform public.create_reservation(
      v_order.restaurant_id,
      (v_booking ->> 'party_size')::integer,
      (v_booking ->> 'starts_at')::timestamptz,
      nullif(v_booking ->> 'stay_minutes', '')::integer,
      nullif(v_booking ->> 'section_id', '')::uuid,
      case when jsonb_typeof(v_booking -> 'table_ids') = 'array'
        then array(select jsonb_array_elements_text(v_booking -> 'table_ids'))::uuid[]
        else null
      end,
      p_order_id
    );
  exception
    when others then
      -- create_reservation() refuses with readable Serbian messages (P0001);
      -- anything else (an exclusion violation from a table taken meanwhile, a
      -- lock timeout) gets a generic one. The subtransaction rolled back
      -- whatever it had started to write.
      v_message := case
        when sqlstate = 'P0001' then sqlerrm
        else 'Termin više nije dostupan.'
      end;
      perform set_config('request.jwt.claims', coalesce(v_previous_claims, ''), true);
      update public.orders
      set pending_booking = null, checkout_total_para = null, stripe_checkout_session_id = null,
          booking_failure = v_message
      where id = p_order_id;
      return 'failed';
  end;

  perform set_config('request.jwt.claims', coalesce(v_previous_claims, ''), true);

  update public.orders
  set payment_status = 'paid', paid_at = now(),
      stripe_checkout_session_id = p_session_id, stripe_payment_intent_id = p_payment_intent_id,
      pending_booking = null, checkout_total_para = null, booking_failure = null
  where id = p_order_id;

  return 'booked';
end;
$$;

revoke all on function public.set_order_pending_booking(uuid, text, jsonb, bigint) from public, anon, authenticated;
revoke all on function public.finalize_paid_booking(uuid, text, text) from public, anon, authenticated;
grant execute on function public.set_order_pending_booking(uuid, text, jsonb, bigint) to service_role;
grant execute on function public.finalize_paid_booking(uuid, text, text) to service_role;
