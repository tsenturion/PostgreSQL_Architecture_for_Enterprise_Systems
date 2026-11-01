#!/usr/bin/env python3
"""Проверяет маршрутизацию, репликацию, TLS и доступность компонентов."""
import json
import os
import sys
import time
from urllib.request import urlopen
import psycopg2


def state(node):
    with urlopen(f"http://{node}:8008/patroni", timeout=3) as response:
        return json.load(response)


def primary():
    for node in ("pg1", "pg2"):
        try:
            data = state(node)
            if data.get("role") in ("primary", "master") and data.get("state") == "running":
                return node
        except (OSError, ValueError):
            pass
    raise RuntimeError("Работающий primary пока не найден.")


def connection(host="rw", port=5432, user="postgres", password=None, database="course"):
    return psycopg2.connect(host=host, port=port, user=user, dbname=database,
                            password=password or os.environ["POSTGRES_PASSWORD"],
                            sslmode="verify-full", sslrootcert="/certs/ca.crt", connect_timeout=4)


def replicas_ready():
    with connection(primary(), database="postgres") as conn:
        with conn.cursor() as cursor:
            cursor.execute("SELECT count(*) FROM pg_stat_replication WHERE state='streaming'")
            if cursor.fetchone()[0] < 1:
                raise RuntimeError("Реплика ещё не перешла в streaming.")


def restore_ready():
    with connection("restore") as conn:
        with conn.cursor() as cursor:
            cursor.execute("SELECT NOT pg_is_in_recovery()")
            if not cursor.fetchone()[0]:
                raise RuntimeError("Восстановление ещё не завершилось.")


def wait(check, seconds=180):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                print(result)
            return
        except (OSError, RuntimeError, ValueError, psycopg2.Error) as error:
            last = str(error).strip()
            time.sleep(2)
    raise RuntimeError(f"Истекло время ожидания: {last}")


def check():
    with open("/etc/course-versions.json", encoding="utf-8") as stream:
        expected = json.load(stream)
    leader = primary()
    print(f"Primary: {leader}")
    replicas_ready()
    for host, port in (("rw", 5432), ("pool", 6432)):
        with connection(host, port) as conn:
            with conn.cursor() as cursor:
                cursor.execute("SELECT pg_is_in_recovery(), current_database(), ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()")
                recovery, database, ssl = cursor.fetchone()
                if recovery or database != "course" or not ssl:
                    raise RuntimeError(f"Не пройдена проверка маршрутизации/TLS через {host}.")
                cursor.execute("SHOW server_version")
                if cursor.fetchone()[0].split()[0] != expected["postgres_version"]:
                    raise RuntimeError(f"Версия PostgreSQL через {host} отличается от versions.json.")
        print(f"Маршрутизация и TLS: {host}:{port} — успешно")
    for role, key in (("course_app", "APP_PASSWORD"), ("course_reader", "READER_PASSWORD"),
                      ("course_migrator", "MIGRATOR_PASSWORD"), ("course_monitor", "MONITOR_PASSWORD")):
        with connection("pool", 6432, role, os.environ[key]) as conn:
            with conn.cursor() as cursor:
                cursor.execute("SELECT count(*) FROM sales.orders")
                if cursor.fetchone()[0] < 1:
                    raise RuntimeError("Учебные заказы отсутствуют.")
                if role == "course_reader":
                    cursor.execute("SELECT has_table_privilege(current_user,'sales.orders','UPDATE')")
                    if cursor.fetchone()[0]:
                        raise RuntimeError("У роли чтения есть лишнее право UPDATE.")
        print(f"Доступ роли {role} — успешно")
    with connection(leader) as conn:
        with conn.cursor() as cursor:
            cursor.execute("SELECT version,orders_count FROM lab.installation WHERE id=1")
            if cursor.fetchone()[0] != 1:
                raise RuntimeError("Неизвестная версия учебной схемы.")
            cursor.execute("SELECT pg_size_pretty(pg_database_size(current_database()))")
            print("Размер учебной базы:", cursor.fetchone()[0])
    for number in range(1, 4):
        with urlopen(f"http://etcd{number}:2379/health", timeout=3) as response:
            health = json.load(response)
            if str(health.get("health")).lower() != "true":
                raise RuntimeError(f"etcd{number} нездоров.")
    print("Реплика streaming, три участника etcd доступны. Проверка завершена.")


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "check"
    try:
        if action == "leader":
            print(primary())
        elif action == "wait-primary":
            wait(primary)
        elif action == "wait-replica":
            wait(replicas_ready)
        elif action == "wait-restore":
            wait(restore_ready)
        elif action == "check":
            check()
        else:
            raise RuntimeError("Неизвестная проверка.")
    except (OSError, RuntimeError, ValueError, psycopg2.Error) as error:
        print(f"Ошибка проверки: {error}", file=sys.stderr)
        sys.exit(1)
