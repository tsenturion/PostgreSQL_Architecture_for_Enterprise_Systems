#!/usr/bin/env python3
"""Записывает небольшие операции и фиксирует результат COMMIT при переключении."""
import datetime
import json
import os
import sys
import time
import uuid
import psycopg2


def emit(**values):
    print(json.dumps({"время": datetime.datetime.now(datetime.timezone.utc).isoformat(), **values}, ensure_ascii=False), flush=True)


def main(seconds):
    if not 1 <= seconds <= 120:
        raise ValueError("Допустимо 1–120 секунд.")
    deadline = time.monotonic() + seconds
    pending = None
    connection = None
    while time.monotonic() < deadline:
        pending = pending or str(uuid.uuid4())
        try:
            if connection is None or connection.closed:
                connection = psycopg2.connect(host="pool", port=6432, user="course_app", dbname="course",
                    password=os.environ["APP_PASSWORD"], sslmode="verify-full", sslrootcert="/certs/ca.crt",
                    connect_timeout=3)
            with connection:
                with connection.cursor() as cursor:
                    cursor.execute("SET LOCAL statement_timeout='3s'")
                    cursor.execute("INSERT INTO lab.client_operations(operation_id,client) VALUES(%s,'наблюдение') ON CONFLICT DO NOTHING", (pending,))
            emit(операция=pending, результат="COMMIT подтверждён")
            pending = None
        except psycopg2.Error as error:
            emit(операция=pending, результат="Ошибка; повтор с тем же идентификатором", ошибка=str(error).strip())
            if connection is not None:
                connection.close()
                connection = None
        time.sleep(0.5)
    if connection is not None:
        connection.close()
    if pending:
        emit(операция=pending, результат="Исход последней операции требует проверки в базе")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 30)
