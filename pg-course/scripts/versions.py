#!/usr/bin/env python3
"""Проверяет версии основных бинарных файлов после сборки служебного образа."""
import json
import subprocess


def check():
    with open("/etc/course-versions.json", encoding="utf-8") as stream:
        expected = json.load(stream)
    commands = [
        (["postgres", "--version"], expected["postgres_version"]),
        (["patroni", "--version"], expected["patroni_version"]),
        (["pgbackrest", "version"], expected["pgbackrest_package"].split("-", 1)[0]),
        (["pgbouncer", "--version"], expected["pgbouncer_package"].split("-", 1)[0]),
    ]
    for command, version in commands:
        output = subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()
        if version not in output.splitlines()[0].split():
            raise RuntimeError(f"Неожиданная версия {' '.join(command)}: {output}")
        print(output)
    import psycopg2
    if psycopg2.__version__.split()[0] != expected["psycopg2_version"]:
        raise RuntimeError("Версия psycopg2 отличается от versions.json.")
    print("psycopg2", psycopg2.__version__)


if __name__ == "__main__":
    check()
