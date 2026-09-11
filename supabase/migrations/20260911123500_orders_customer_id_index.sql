-- The partial unique index from create_orders.sql only covers status =
-- 'draft' rows. The "Customers can view their own orders" RLS policy
-- filters on customer_id across every status, so confirmed-order lookups
-- (a future order-history page, the owner/staff confirmed-order policies'
-- own customer_id-agnostic restaurant_id filter aside) had no index to use
-- and would sequential-scan as the table grows.
create index orders_customer_id_idx on public.orders (customer_id);
