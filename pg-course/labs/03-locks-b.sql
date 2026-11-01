-- Сеанс Б: строка уже занята сеансом А.
SET lock_timeout='15s';
UPDATE sales.orders SET updated_at=clock_timestamp() WHERE order_id=1;
-- После опыта: RESET lock_timeout;
