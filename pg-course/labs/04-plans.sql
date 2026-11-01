-- План запроса до создания индекса по customer_id.
EXPLAIN (ANALYZE,BUFFERS)
SELECT order_id,created_at,status,amount FROM sales.orders
WHERE customer_id=42 ORDER BY created_at DESC LIMIT 20;

-- На маленькой таблице выбор последовательного чтения может быть обоснованным.
-- Оцениваем также число прочитанных блоков и точность оценки строк.
CREATE INDEX IF NOT EXISTS orders_customer_date_idx ON sales.orders(customer_id,created_at DESC);
ANALYZE sales.orders;
EXPLAIN (ANALYZE,BUFFERS)
SELECT order_id,created_at,status,amount FROM sales.orders
WHERE customer_id=42 ORDER BY created_at DESC LIMIT 20;
-- При необходимости вернуть исходное состояние вручную:
-- DROP INDEX sales.orders_customer_date_idx;
