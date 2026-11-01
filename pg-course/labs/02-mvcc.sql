-- SQL-блоки для двух сеансов: А удерживает снимок, Б изменяет строку и запускает VACUUM.
-- Сеанс А: удерживаем снимок и сравниваем видимость данных.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT order_id,status FROM sales.orders WHERE order_id=1;

-- Сеанс Б: изменяем строку, затем запускаем очистку.
-- UPDATE sales.orders SET status='mvcc_demo' WHERE order_id=1;
-- VACUUM (VERBOSE) sales.orders;

-- Сеанс А: снимок по-прежнему показывает прежнее состояние.
SELECT order_id,status FROM sales.orders WHERE order_id=1;
COMMIT;
-- Сеанс Б: после завершения снимка повторить VACUUM (VERBOSE) sales.orders.
