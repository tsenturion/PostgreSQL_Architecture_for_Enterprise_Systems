#!/usr/bin/env python3
"""Проверяет публикацию портов, не останавливая существующие службы."""
import ipaddress
import json
from pathlib import Path
import socket
import subprocess
import sys

from configure import PORTS, read_env


def owned_ports(home):
    result = subprocess.run(["docker", "ps", "-a", "--filter", "label=com.docker.compose.project=pgcourse", "--format", "{{.ID}}"],
                            check=True, capture_output=True, text=True)
    ids = result.stdout.split()
    if not ids:
        return set()
    result = subprocess.run(["docker", "inspect", *ids], check=True, capture_output=True, text=True)
    ports = set()
    for container in json.loads(result.stdout):
        origin = container.get("Config", {}).get("Labels", {}).get("com.docker.compose.project.working_dir", "")
        if not origin or Path(origin).resolve() != home.resolve():
            raise RuntimeError("Имя Docker-проекта pgcourse уже используется другим каталогом. Его контейнеры не изменены.")
        for bindings in container.get("NetworkSettings", {}).get("Ports", {}).values():
            for binding in bindings or []:
                ports.add((binding["HostIp"], int(binding["HostPort"])))
    return ports


def main(home):
    values = read_env(home / ".env")
    address = str(ipaddress.IPv4Address(values["BIND_ADDRESS"]))
    owned = owned_ports(home)
    for port in PORTS:
        if (address, port) in owned:
            continue
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            try:
                listener.bind((address, port))
            except OSError as error:
                raise RuntimeError(f"Нельзя использовать {address}:{port}: {error}. Существующая служба не изменена.") from error
    docker_root = subprocess.run(["docker", "info", "--format", "{{.DockerRootDir}}"],
                                 check=True, capture_output=True, text=True).stdout.strip()
    import shutil
    if shutil.disk_usage(docker_root).free < 4 * 1024**3:
        raise RuntimeError(f"В файловой системе Docker ({docker_root}) нужно не менее 4 ГиБ свободного места.")
    print("Порты доступны либо уже принадлежат стенду; место для образов Docker проверено.")


if __name__ == "__main__":
    try:
        main(Path(sys.argv[1]))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"Ошибка предварительной проверки: {error}")
