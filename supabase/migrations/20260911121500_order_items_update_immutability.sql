-- create_order_items.sql relied on a column-level grant (`grant update
-- (quantity) on order_items to authenticated`) to stop a customer from
-- updating unit_price/item_name/menu_item_id/order_id directly - CI's
-- pgTAP suite showed that grant alone doesn't reliably reject an update
-- naming a different column in this setup, so the actual enforcement now
-- lives in the policy's WITH CHECK instead: every column except quantity
-- must still equal whatever is currently stored for that row. This is the
-- same "pin everything but the one editable column" idiom, just expressed
-- as a row check instead of a column grant - and RLS WITH CHECK violations
-- already reliably raise 42501 elsewhere in this project (see
-- menu_items.category_id's cross-restaurant check).
--
-- Table-level update is granted now (not column-restricted) since the
-- WITH CHECK clause is what actually does the restricting.
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
    and order_id = (select oi.order_id from public.order_items oi where oi.id = order_items.id)
    and menu_item_id is not distinct from (select oi.menu_item_id from public.order_items oi where oi.id = order_items.id)
    and item_name = (select oi.item_name from public.order_items oi where oi.id = order_items.id)
    and unit_price = (select oi.unit_price from public.order_items oi where oi.id = order_items.id)
  );

grant update on public.order_items to authenticated;
