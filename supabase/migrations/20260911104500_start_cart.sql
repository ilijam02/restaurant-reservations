-- Creates or replaces the caller's draft cart for a given restaurant.
-- security definer so it can write despite orders granting no insert to
-- authenticated (see create_orders.sql); set search_path = '' per this
-- project's standard for security-definer functions (every reference here
-- is schema-qualified).
--
-- A customer has at most one 'draft' order at a time (enforced by the
-- partial unique index on orders), so this is the single place that
-- invariant is maintained: already drafting at this restaurant just
-- returns that row unchanged; drafting at a different restaurant deletes
-- the old draft (cascading to its order_items/order_item_choices) and
-- starts a fresh one. The row is locked with "for update" before that
-- decision so two rapid calls (e.g. a double-mounted effect) can't both
-- decide to insert; a unique_violation is still caught as a last-resort
-- safety net (e.g. a second browser tab racing this one) by just
-- re-reading and returning whatever draft ended up committed.
create or replace function public.start_cart(p_restaurant_id uuid)
returns public.orders
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'customer') then
    raise exception 'Samo nalozi tipa kupac mogu praviti porudžbine.';
  end if;

  if not exists (select 1 from public.restaurants where id = p_restaurant_id) then
    raise exception 'Restoran ne postoji.';
  end if;

  select * into v_order from public.orders where customer_id = auth.uid() and status = 'draft' for update;

  if found then
    if v_order.restaurant_id = p_restaurant_id then
      return v_order;
    end if;
    delete from public.orders where id = v_order.id;
  end if;

  insert into public.orders (restaurant_id, customer_id, status)
  values (p_restaurant_id, auth.uid(), 'draft')
  returning * into v_order;

  return v_order;
exception
  when unique_violation then
    select * into v_order from public.orders where customer_id = auth.uid() and status = 'draft';
    return v_order;
end;
$$;

grant execute on function public.start_cart(uuid) to authenticated;
