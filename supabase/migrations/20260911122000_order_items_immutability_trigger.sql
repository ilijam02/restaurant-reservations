-- The previous migration's WITH CHECK self-reference (comparing each
-- column against a subquery re-selecting the same row by id) turned out to
-- also reject legitimate quantity-only updates in practice - the
-- self-referencing subquery's snapshot semantics under RLS aren't the
-- simple "see the old row" behavior that pattern is often assumed to have.
-- Reverting the policy to the original plain ownership/draft check and
-- moving the actual "only quantity may change" enforcement into an
-- ordinary BEFORE UPDATE trigger instead - triggers get OLD/NEW directly,
-- with no snapshot ambiguity.
drop policy "Customers can update quantity on their own draft order items" on public.order_items;

create policy "Customers can update quantity on their own draft order items"
  on public.order_items for update
  to authenticated
  using (
    exists (
      select 1 from public.orders o
      where o.id = order_id and o.customer_id = auth.uid() and o.status = 'draft'
    )
  )
  with check (
    exists (
      select 1 from public.orders o
      where o.id = order_id and o.customer_id = auth.uid() and o.status = 'draft'
    )
  );

-- security definer + search_path = '' per this project's standard (see
-- create_reservation()'s comment block) - not strictly needed for a
-- trigger that only reads OLD/NEW, but keeps the convention consistent and
-- avoids any search_path ambiguity in the raise message.
create or replace function public.protect_order_item_immutable_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.order_id <> old.order_id
    or new.menu_item_id is distinct from old.menu_item_id
    or new.item_name <> old.item_name
    or new.unit_price <> old.unit_price
  then
    raise exception 'Samo količina porudžbine može da se menja.' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger order_items_protect_immutable_columns
  before update on public.order_items
  for each row
  execute function public.protect_order_item_immutable_columns();
