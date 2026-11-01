-- Сеанс А: открытая транзакция удерживает блокировку строки.
BEGIN;
UPDATE sales.orders SET updated_at=clock_timestamp() WHERE order_id=1;
-- Связанный запрос сеанса Б: labs/03-locks-b.sql.
-- Наблюдение за ожиданиями: pg_blocking_pids и журналы.
-- Отмена транзакции в сеансе А: ROLLBACK;
