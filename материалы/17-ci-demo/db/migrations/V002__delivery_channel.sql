ALTER TABLE delivery17.orders
    ADD COLUMN delivery_channel text,
    ADD CONSTRAINT orders_delivery_channel_check
        CHECK (delivery_channel IN ('courier', 'pickup'));
