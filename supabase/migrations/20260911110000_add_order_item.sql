-- Adds one line to the caller's own draft order, snapshotting name/price
-- server-side - the client only ever sends a menu item id, chosen option
-- choice ids, and a quantity, never a price (see create_order_items.sql's
-- comment on why). security definer / search_path = '' for the same
-- reasons as create_reservation() and start_cart().
--
-- Every choice id is validated to belong to one of p_menu_item_id's own
-- option groups (not just to *some* menu item's options - choice ids
-- aren't secret, same reasoning as menu_items.category_id's cross-
-- restaurant check), duplicates are rejected, and each option group's own
-- is_required/allow_multiple rules are enforced against how many of its
-- choices were actually selected. unit_price is the item's current base
-- price plus every selected choice's price_delta, summed in one query -
-- coalesce covers both "no choices selected" (sum() over zero rows is
-- null) and "item has no options at all".
create or replace function public.add_order_item(
  p_order_id uuid,
  p_menu_item_id uuid,
  p_choice_ids uuid[] default '{}',
  p_quantity integer default 1
)
returns public.order_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_item public.menu_items;
  v_choice_ids uuid[];
  v_unit_price numeric(10, 2);
  v_order_item_id uuid;
  v_order_item public.order_items;
  r record;
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Količina mora biti veća od nule.';
  end if;

  v_choice_ids := coalesce(p_choice_ids, '{}');

  select * into v_order from public.orders where id = p_order_id and customer_id = auth.uid() for update;
  if not found then
    raise exception 'Korpa ne postoji.';
  end if;
  if v_order.status <> 'draft' then
    raise exception 'Korpa je već poslata.';
  end if;

  select * into v_item from public.menu_items where id = p_menu_item_id and restaurant_id = v_order.restaurant_id;
  if not found then
    raise exception 'Stavka ne postoji u ovom restoranu.';
  end if;
  if not v_item.is_available then
    raise exception 'Stavka trenutno nije dostupna.';
  end if;

  if cardinality(v_choice_ids) > 0 then
    if cardinality(v_choice_ids) <> cardinality(array(select distinct unnest(v_choice_ids))) then
      raise exception 'Isti izbor je naveden više puta.';
    end if;

    if exists (
      select 1 from unnest(v_choice_ids) as cid
      where not exists (
        select 1 from public.menu_item_option_choices c
        join public.menu_item_options o on o.id = c.option_id
        where c.id = cid and o.menu_item_id = p_menu_item_id
      )
    ) then
      raise exception 'Izabrana opcija ne pripada ovoj stavci.';
    end if;
  end if;

  for r in (
    select
      o.name,
      o.is_required,
      o.allow_multiple,
      (
        select count(*) from unnest(v_choice_ids) as cid
        join public.menu_item_option_choices c on c.id = cid
        where c.option_id = o.id
      ) as selected_count
    from public.menu_item_options o
    where o.menu_item_id = p_menu_item_id
  )
  loop
    if r.is_required and r.selected_count = 0 then
      raise exception 'Grupa opcija "%" je obavezna.', r.name;
    end if;
    if not r.allow_multiple and r.selected_count > 1 then
      raise exception 'Grupa opcija "%" dozvoljava samo jedan izbor.', r.name;
    end if;
  end loop;

  select v_item.price + coalesce(sum(c.price_delta), 0) into v_unit_price
  from unnest(v_choice_ids) as cid
  join public.menu_item_option_choices c on c.id = cid;

  insert into public.order_items (order_id, menu_item_id, item_name, unit_price, quantity)
  values (p_order_id, p_menu_item_id, v_item.name, v_unit_price, p_quantity)
  returning id into v_order_item_id;

  insert into public.order_item_choices (order_item_id, choice_id, option_name, choice_name, price_delta)
  select v_order_item_id, c.id, o.name, c.name, c.price_delta
  from unnest(v_choice_ids) as cid
  join public.menu_item_option_choices c on c.id = cid
  join public.menu_item_options o on o.id = c.option_id;

  select * into v_order_item from public.order_items where id = v_order_item_id;
  return v_order_item;
end;
$$;

grant execute on function public.add_order_item(uuid, uuid, uuid[], integer) to authenticated;
