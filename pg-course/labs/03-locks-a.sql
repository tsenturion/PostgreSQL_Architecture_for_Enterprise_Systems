-- Сеанс А: выполнить вручную, оставить транзакцию открытой.
BEGIN;
UPDATE sales.orders SET updated_at=clock_timestamp() WHERE order_id=1;
-- В сеансе Б выполнить labs/03-locks-b.sql.
-- В третьем сеансе посмотреть pg_blocking_pids и журналы.
-- Завершение эксперимента в сеансе А: ROLLBACK;
