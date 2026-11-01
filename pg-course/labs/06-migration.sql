-- CREATE INDEX CONCURRENTLY выполняется отдельной командой вне блока BEGIN/COMMIT.
SET lock_timeout='3s';
ALTER TABLE sales.orders ADD COLUMN IF NOT EXISTS delivery_note text;
-- Порция заполнения на 1000 строк.
WITH batch AS (
  SELECT order_id FROM sales.orders WHERE delivery_note IS NULL ORDER BY order_id LIMIT 1000
)
UPDATE sales.orders AS o SET delivery_note='Уточнить при доставке'
FROM batch WHERE o.order_id=batch.order_id;
CREATE INDEX CONCURRENTLY IF NOT EXISTS orders_created_idx ON sales.orders(created_at);
SELECT pid,phase,blocks_total,blocks_done FROM pg_stat_progress_create_index;
RESET lock_timeout;
