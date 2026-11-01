\set order_id random(1, :orders)
BEGIN;
SELECT order_id,status,amount FROM sales.orders WHERE order_id=:order_id;
UPDATE sales.orders SET updated_at=clock_timestamp() WHERE order_id=:order_id;
COMMIT;
