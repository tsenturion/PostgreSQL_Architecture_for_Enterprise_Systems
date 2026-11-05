BEGIN;
SELECT set_config('delivery17.expected_release', :'release_id', true);

-- Две версии клиента работают с одной схемой после расширения.
INSERT INTO delivery17.orders (order_id, status) VALUES (102, 'paid');
INSERT INTO delivery17.orders (order_id, status, delivery_channel)
VALUES (103, 'paid', 'pickup');

DO $test$
BEGIN
    IF (SELECT count(*) FROM delivery17.orders
        WHERE order_id IN (101, 102) AND status = 'paid'
          AND delivery_channel IS NULL) <> 2 THEN
        RAISE EXCEPTION 'Старые данные или контракт старого клиента нарушены';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM delivery17.orders
                   WHERE order_id = 103 AND delivery_channel = 'pickup') THEN
        RAISE EXCEPTION 'Новый клиент не сохранил канал доставки';
    END IF;
    IF (SELECT array_agg(release_id ORDER BY version) FROM delivery17.schema_history)
           IS DISTINCT FROM ARRAY['fixture-v1', current_setting('delivery17.expected_release')] THEN
        RAISE EXCEPTION 'История версий отличается от ожидаемой';
    END IF;
    BEGIN
        INSERT INTO delivery17.orders (order_id, status, delivery_channel)
        VALUES (104, 'paid', 'invalid');
        RAISE EXCEPTION 'База приняла недопустимый канал доставки';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
END
$test$;
ROLLBACK;
