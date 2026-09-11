-- Bug found in code review: the immutability trigger added in
-- 20260911122000 also rejected menu_item_id changing to null - but that's
-- exactly what happens internally when an owner deletes a menu item (the
-- "on delete set null" foreign key action is implemented as an UPDATE on
-- the referencing row, which fires this same BEFORE UPDATE trigger). That
-- made deleting any menu item that had ever been ordered fail outright,
-- defeating the whole point of "on delete set null" (see
-- create_order_items.sql's comment: historic order lines should keep
-- their snapshot, not block the delete).
--
-- menu_item_id was never a financial field to begin with - item_name and
-- unit_price are the actual price-bearing snapshot, already protected
-- below, so dropping menu_item_id from this check doesn't reopen the
-- price-tampering gap this trigger exists for.
create or replace function public.protect_order_item_immutable_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.order_id <> old.order_id
    or new.item_name <> old.item_name
    or new.unit_price <> old.unit_price
  then
    raise exception 'Samo količina porudžbine može da se menja.' using errcode = '42501';
  end if;
  return new;
end;
$$;
