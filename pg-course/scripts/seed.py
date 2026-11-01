#!/usr/bin/env python3
"""Однократно создаёт роли, учебную схему и небольшой набор данных."""
import os
import time
import psycopg2
from psycopg2 import sql


def connect(database):
    deadline = time.monotonic() + 90
    while True:
        try:
            return psycopg2.connect(dbname=database, connect_timeout=4)
        except psycopg2.OperationalError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(2)


def main():
    admin = connect("postgres")
    admin.autocommit = True
    with admin.cursor() as cursor:
        cursor.execute("SELECT pg_advisory_lock(805301)")
        cursor.execute("SELECT 1 FROM pg_database WHERE datname = 'course'")
        exists = cursor.fetchone() is not None
    if exists:
        connection = connect("course")
        with connection.cursor() as cursor:
            cursor.execute("SELECT to_regclass('lab.installation')")
            installed = cursor.fetchone()[0] is not None
            if installed:
                cursor.execute("SELECT version FROM lab.installation WHERE id=1")
                row = cursor.fetchone()
                if row != (1,):
                    raise RuntimeError("Неизвестная версия учебной схемы; данные автоматически не изменяются.")
                print("Учебная база уже подготовлена. Данные и пароли ролей не изменены.")
                connection.close()
                admin.close()
                return
        connection.close()
    with admin.cursor() as cursor:
        roles = {"course_owner": None, "course_app": "APP_PASSWORD", "course_reader": "READER_PASSWORD",
                 "course_migrator": "MIGRATOR_PASSWORD", "course_monitor": "MONITOR_PASSWORD"}
        for role, key in roles.items():
            cursor.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (role,))
            if not cursor.fetchone():
                statement = sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(role)) if key is None else \
                    sql.SQL("CREATE ROLE {} LOGIN PASSWORD {}").format(sql.Identifier(role), sql.Literal(os.environ[key]))
                cursor.execute(statement)
        cursor.execute("GRANT course_owner TO course_migrator")
        cursor.execute("GRANT pg_monitor TO course_monitor")
        if not exists:
            cursor.execute("CREATE DATABASE course OWNER course_owner")
    connection = connect("course")
    with connection:
        with connection.cursor() as cursor:
            cursor.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
            cursor.execute("SET ROLE course_owner")
            cursor.execute("""
                CREATE SCHEMA IF NOT EXISTS sales AUTHORIZATION course_owner;
                CREATE SCHEMA IF NOT EXISTS lab AUTHORIZATION course_owner;
                CREATE TABLE sales.customers (
                    customer_id bigint PRIMARY KEY, name text NOT NULL, region text NOT NULL
                );
                CREATE TABLE sales.orders (
                    order_id bigint PRIMARY KEY,
                    customer_id bigint NOT NULL REFERENCES sales.customers,
                    created_at timestamptz NOT NULL,
                    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
                    status text NOT NULL, amount numeric(12,2) NOT NULL, note text NOT NULL
                );
                CREATE TABLE sales.order_items (
                    item_id bigint PRIMARY KEY, order_id bigint NOT NULL REFERENCES sales.orders,
                    product_id integer NOT NULL, quantity integer NOT NULL, description text NOT NULL
                );
                CREATE INDEX order_items_order_idx ON sales.order_items(order_id);
                CREATE TABLE lab.restore_probe (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                    created_at timestamptz NOT NULL DEFAULT clock_timestamp(), message text NOT NULL);
                CREATE TABLE lab.client_operations (operation_id uuid PRIMARY KEY,
                    created_at timestamptz NOT NULL DEFAULT clock_timestamp(), client text NOT NULL);
                INSERT INTO lab.restore_probe(message) VALUES ('Контрольная запись после установки');
                CREATE TABLE lab.installation (id integer PRIMARY KEY CHECK (id=1), version integer NOT NULL,
                    installed_at timestamptz NOT NULL DEFAULT clock_timestamp(), orders_count integer NOT NULL);
                INSERT INTO sales.customers
                    SELECT n, 'Покупатель ' || n, (ARRAY['Урал','Сибирь','Центр','Юг'])[1+n%4]
                    FROM generate_series(1,10000) AS n;
            """)
            count = int(os.environ["ORDERS"])
            cursor.execute("""
                INSERT INTO sales.orders
                SELECT n, 1+mod(n,10000), timestamptz '2026-01-01 00:00:00+00' + mod(n,180)*interval '1 day',
                    clock_timestamp(), (ARRAY['new','paid','shipped'])[1+mod(n,3)],
                    (100+mod(n,100000))::numeric/10, repeat('Учебный заказ. ',5)
                FROM generate_series(1,%s) AS n;
            """, (count,))
            cursor.execute("""
                INSERT INTO sales.order_items
                SELECT n, 1+(n-1)/3, mod(n,2000)::integer, 1+mod(n,5)::integer,
                    repeat('Описание позиции. ',4)
                FROM generate_series(1,%s) AS n;
            """, (count * 3,))
            cursor.execute("""
                REVOKE CREATE ON SCHEMA public FROM PUBLIC;
                GRANT CONNECT ON DATABASE course TO course_app,course_reader,course_migrator,course_monitor;
                GRANT USAGE ON SCHEMA sales,lab TO course_app,course_reader,course_monitor;
                GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA sales TO course_app;
                GRANT SELECT,INSERT,UPDATE,DELETE ON lab.restore_probe TO course_app;
                GRANT SELECT,INSERT ON lab.client_operations TO course_app;
                GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA lab TO course_app;
                GRANT SELECT ON ALL TABLES IN SCHEMA sales,lab TO course_reader,course_monitor;
                ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA sales
                    GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO course_app;
                ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA sales
                    GRANT SELECT ON TABLES TO course_reader,course_monitor;
                ANALYZE sales.customers;
                ANALYZE sales.orders;
                ANALYZE sales.order_items;
            """)
            cursor.execute("INSERT INTO lab.installation(id,version,orders_count) VALUES(1,1,%s)", (count,))
    connection.close()
    admin.close()
    print(f"Созданы учебные роли и база: {count} заказов, {count*3} позиций.")


if __name__ == "__main__":
    main()
