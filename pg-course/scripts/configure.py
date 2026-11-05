#!/usr/bin/env python3
"""Формирует конфигурацию стенда, сохраняя секреты и пользовательские данные."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import secrets

PASSWORD_KEYS = (
    "POSTGRES_PASSWORD", "REPLICATION_PASSWORD", "PATRONI_API_PASSWORD",
    "APP_PASSWORD", "READER_PASSWORD", "MIGRATOR_PASSWORD", "MONITOR_PASSWORD",
    "GRAFANA_PASSWORD",
)
VERSIONS = json.loads((Path(__file__).resolve().parents[1] / "versions.json").read_text(encoding="utf-8"))
PG_MAJOR = int(VERSIONS["postgres_major"])
PGDATA = f"/var/lib/postgresql/{PG_MAJOR}/docker"
PORTS = (5432, 5433, 5434, 5435, 6432, 8008, 8009, 3000, 9090)


def write(path, content, mode=0o644):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    content = content.replace("\r\n", "\n")
    data = content.encode("utf-8")
    changed = not path.exists() or path.read_bytes() != data
    if changed:
        temporary = path.with_name(path.name + ".tmp")
        temporary.write_bytes(data)
        temporary.replace(path)
    os.chmod(path, mode)
    return changed


def read_env(path):
    values = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                key, value = line.split("=", 1)
                values[key] = value
    return values


def settings(home, bind=None, orders=None):
    path = home / ".env"
    values = read_env(path)
    if not values:
        if any((home / "data" / node / str(PG_MAJOR) / "docker" / "PG_VERSION").exists() for node in ("pg1", "pg2")):
            raise ValueError("Есть данные PostgreSQL, но утрачен .env. Восстановите исходные секреты.")
        values = {key: secrets.token_hex(24) for key in PASSWORD_KEYS}
        values.update(BIND_ADDRESS=bind or "127.0.0.1", ORDERS=str(orders or 50000))
    else:
        if bind and bind != values.get("BIND_ADDRESS"):
            raise ValueError("Адрес уже сохранён в .env. Для смены адреса отредактируйте BIND_ADDRESS в .env и повторите установку.")
        if orders and str(orders) != values.get("ORDERS"):
            raise ValueError("Число заказов уже сохранено. Повторная установка не пересоздаёт учебные данные.")
    if not isinstance(ipaddress.ip_address(values["BIND_ADDRESS"]), ipaddress.IPv4Address):
        raise ValueError("BIND_ADDRESS должен быть IPv4-адресом.")
    if not 1000 <= int(values["ORDERS"]) <= 100000:
        raise ValueError("ORDERS должен быть в диапазоне 1000–100000.")
    for key in PASSWORD_KEYS:
        if not values.get(key) or any(c not in "0123456789abcdef" for c in values[key]):
            raise ValueError(f"Повреждён секрет {key} в .env; восстановите исходный файл.")
    write(path, "".join(f"{key}={value}\n" for key, value in values.items()), 0o600)
    return values


def generate(home, values):
    def dump(relative, value):
        write(home / relative, json.dumps(value, ensure_ascii=False, indent=2) + "\n")

    cluster = ",".join(f"etcd{i}=http://etcd{i}:2380" for i in range(1, 4))
    services = {}
    logs = {"driver": "none"}
    certs = [f"./certs/{name}:/certs/{name}:ro" for name in ("ca.crt", "server.crt", "server.key")]
    common = {
        "image": f"pg-course-local:{PG_MAJOR}", "pull_policy": "never",
        "restart": "unless-stopped", "init": False, "env_file": [".env"],
        "logging": logs, "networks": ["course"], "cpus": 0.75,
    }
    for i in range(1, 4):
        name = f"etcd{i}"
        services[name] = {
            "image": VERSIONS["etcd_image"], "restart": "unless-stopped",
            "user": "1000:1000", "logging": logs, "networks": ["course"],
            "mem_limit": "128m", "cpus": 0.25,
            "entrypoint": ["/usr/local/bin/etcd"],
            "command": [
                f"--name={name}", "--data-dir=/etcd-data",
                "--listen-client-urls=http://0.0.0.0:2379",
                f"--advertise-client-urls=http://{name}:2379",
                "--listen-peer-urls=http://0.0.0.0:2380",
                f"--initial-advertise-peer-urls=http://{name}:2380",
                f"--initial-cluster={cluster}", "--initial-cluster-token=pg-course-v1",
                "--initial-cluster-state=new", "--auto-compaction-retention=1h",
                "--enable-grpc-gateway=true",
                "--quota-backend-bytes=33554432", "--max-wals=2", "--max-snapshots=2",
                "--snapshot-count=1000", "--logger=zap", "--log-level=info",
                "--log-outputs=/logs/service.log",
            ],
            "volumes": [f"./data/{name}:/etcd-data", f"./logs/{name}:/logs"],
            "healthcheck": {
                "test": ["CMD", "/usr/local/bin/etcdctl", "--endpoints=http://127.0.0.1:2379", "endpoint", "health"],
                "interval": "10s", "timeout": "4s", "retries": 12,
            },
        }
    parameters = {
        "shared_buffers": "64MB", "work_mem": "2MB", "maintenance_work_mem": "32MB",
        "max_connections": 40, "max_wal_size": "256MB", "min_wal_size": "64MB",
        "max_slot_wal_keep_size": "128MB", "wal_keep_size": "32MB",
        "wal_level": "replica", "wal_log_hints": "on", "max_wal_senders": 8,
        "max_replication_slots": 8, "hot_standby": "on", "password_encryption": "scram-sha-256",
        "shared_preload_libraries": "pg_stat_statements", "track_io_timing": "on",
        "archive_mode": "on", "archive_timeout": "60s",
        "archive_command": "pgbackrest --stanza=course archive-push %p",
        "restore_command": "pgbackrest --stanza=course archive-get %f %p",
        "ssl": "on", "ssl_cert_file": "/certs/server.crt", "ssl_key_file": "/certs/server.key",
        "ssl_ca_file": "/certs/ca.crt", "logging_collector": "off",
        "log_line_prefix": "%m [postgres:%p] %u@%d app=%a client=%h ",
        "log_min_duration_statement": "500ms", "log_lock_waits": "on",
        "deadlock_timeout": "1s", "log_checkpoints": "on", "log_connections": "on",
        "log_disconnections": "on", "idle_in_transaction_session_timeout": "5min",
        "unix_socket_directories": "/var/run/postgresql",
    }
    for i in (1, 2):
        name = f"pg{i}"
        patroni = {
            "scope": "course", "namespace": "/pg-course/", "name": name,
            "restapi": {"listen": "0.0.0.0:8008", "connect_address": f"{name}:8008",
                        "authentication": {"username": "admin", "password": values["PATRONI_API_PASSWORD"]}},
            "etcd3": {"hosts": [f"etcd{n}:2379" for n in range(1, 4)]},
            "bootstrap": {
                "dcs": {"ttl": 30, "loop_wait": 5, "retry_timeout": 5,
                        "maximum_lag_on_failover": 1048576, "check_timeline": True,
                        "postgresql": {"use_pg_rewind": True, "use_slots": True, "parameters": parameters}},
                "initdb": [{"encoding": "UTF8"}, {"locale": "C.UTF-8"}, "data-checksums"],
            },
            "postgresql": {
                "listen": "0.0.0.0:5432", "connect_address": f"{name}:5432",
                "data_dir": PGDATA, "bin_dir": f"/usr/lib/postgresql/{PG_MAJOR}/bin",
                "pgpass": "/tmp/pgpass", "parameters": parameters,
                "authentication": {
                    "superuser": {"username": "postgres", "password": values["POSTGRES_PASSWORD"]},
                    "replication": {"username": "replicator", "password": values["REPLICATION_PASSWORD"]},
                    "rewind": {"username": "postgres", "password": values["POSTGRES_PASSWORD"]},
                },
                "pg_hba": [
                    "local all postgres peer", "local all all scram-sha-256",
                    "hostssl replication replicator all scram-sha-256",
                    "hostssl all all all scram-sha-256",
                ],
                "create_replica_methods": ["basebackup"],
                "basebackup": [{"checkpoint": "fast"}],
            },
            "watchdog": {"mode": "off"},
            "tags": {"nofailover": False, "noloadbalance": False, "clonefrom": False, "nosync": False},
        }
        dump(f"config/{name}/patroni.json", patroni)
        write(home / f"config/{name}/pgbackrest.conf", f"""[global]
repo1-path=/var/lib/pgbackrest/repo
repo1-retention-full=2
repo1-retention-archive=2
repo1-retention-archive-type=full
lock-path=/var/lib/pgbackrest/lock
log-path=/var/log/course/pgbackrest
log-level-console=info
log-level-file=info
process-max=1
compress-type=gz
compress-level=1
start-fast=y

[course]
pg1-path={PGDATA}
pg1-port=5432
pg1-socket-path=/var/run/postgresql
""")
        service = dict(common)
        service.update(
            command=["patroni"], mem_limit="512m", shm_size="128m",
            environment={"PGDATA": PGDATA},
            ports=[f"${{BIND_ADDRESS}}:{5432+i}:5432", f"${{BIND_ADDRESS}}:{8007+i}:8008"],
            volumes=[f"./data/{name}:/var/lib/postgresql", f"./config/{name}:/etc/course:ro",
                     f"./config/{name}/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro",
                     "./backups:/var/lib/pgbackrest", "./data/restore:/restore",
                     f"./logs/{name}:/var/log/course"] + certs,
            depends_on={f"etcd{n}": {"condition": "service_healthy"} for n in range(1, 4)},
            healthcheck={"test": ["CMD", "curl", "-fsS", "http://127.0.0.1:8008/health"],
                         "interval": "10s", "timeout": "4s", "retries": 18, "start_period": "30s"},
        )
        if i == 1:
            service["build"] = {"context": "./image", "args": {
                "POSTGRES_IMAGE": VERSIONS["postgres_image"], "EXPORTER_IMAGE": VERSIONS["exporter_image"],
                "PATRONI_VERSION": VERSIONS["patroni_version"], "PSYCOPG2_VERSION": VERSIONS["psycopg2_version"],
                "PGBACKREST_PACKAGE": VERSIONS["pgbackrest_package"], "PGBOUNCER_PACKAGE": VERSIONS["pgbouncer_package"],
            }}
        services[name] = service
    proxy_path = home / "config/proxy/haproxy.cfg"
    proxy_existed = proxy_path.exists()
    proxy_changed = write(proxy_path, """global
    log stdout format raw local0
    maxconn 100
defaults
    log global
    mode tcp
    option tcplog
    timeout connect 3s
    timeout client 10m
    timeout server 10m
resolvers docker_dns
    nameserver docker 127.0.0.11:53
    resolve_retries 3
    timeout resolve 1s
    timeout retry 1s
    hold valid 5s
frontend postgres_write
    bind *:5432
    default_backend postgres_primary
backend postgres_primary
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 2s fall 2 rise 2 on-marked-down shutdown-sessions
    server pg1 pg1:5432 check port 8008 resolvers docker_dns resolve-prefer ipv4 init-addr last,libc,none
    server pg2 pg2:5432 check port 8008 resolvers docker_dns resolve-prefer ipv4 init-addr last,libc,none
""")
    if proxy_changed and proxy_existed:
        write(home / "state/reload-proxy", "Требуется применить обновлённую конфигурацию HAProxy.\n", 0o600)
    write(home / "config/pool/pgbouncer.ini", """[databases]
course = host=rw port=5432 dbname=course
postgres = host=rw port=5432 dbname=postgres

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
unix_socket_dir = /tmp
pidfile = /tmp/pgbouncer.pid
auth_type = scram-sha-256
auth_file = /etc/course/userlist.txt
admin_users = postgres
stats_users = course_monitor
pool_mode = transaction
max_client_conn = 50
default_pool_size = 5
reserve_pool_size = 1
max_db_connections = 16
server_connect_timeout = 5
server_login_retry = 2
query_wait_timeout = 30
client_tls_sslmode = require
client_tls_cert_file = /certs/server.crt
client_tls_key_file = /certs/server.key
server_tls_sslmode = verify-full
server_tls_ca_file = /certs/ca.crt
log_connections = 1
log_disconnections = 1
""")
    roles = {"postgres": "POSTGRES_PASSWORD", "course_app": "APP_PASSWORD", "course_reader": "READER_PASSWORD",
             "course_migrator": "MIGRATOR_PASSWORD", "course_monitor": "MONITOR_PASSWORD"}
    write(home / "config/pool/userlist.txt", "".join(f'"{role}" "{values[key]}"\n' for role, key in roles.items()))
    services["rw"] = {
        "image": VERSIONS["haproxy_image"], "pull_policy": "missing", "restart": "unless-stopped",
        "user": "999:999", "logging": logs, "networks": ["course"], "cpus": 0.75, "mem_limit": "64m",
        "ports": ["${BIND_ADDRESS}:5432:5432"],
        "entrypoint": ["/bin/sh", "-c"],
        "command": ["exec haproxy -W -db -f /etc/course/haproxy.cfg >> /var/log/course/service.log 2>&1"],
        "volumes": ["./config/proxy:/etc/course:ro", "./logs/rw:/var/log/course"],
    }
    services["pool"] = dict(common, command=["pool"], mem_limit="96m",
                            ports=["${BIND_ADDRESS}:6432:6432"],
                            volumes=["./config/pool:/etc/course:ro", "./logs/pool:/var/log/course"] + certs,
                            tmpfs=["/var/lib/postgresql:size=1m", "/tmp:size=16m"])
    services["tools"] = dict(common, profiles=["tools"], restart="no", command=["tool", "psql"],
                             mem_limit="192m", tmpfs=["/var/lib/postgresql:size=1m", "/tmp:size=16m"],
                             environment={"PGHOST": "rw", "PGPORT": "5432", "PGUSER": "postgres",
                                          "PGDATABASE": "course", "PGPASSWORD": "${POSTGRES_PASSWORD}",
                                          "PGSSLMODE": "verify-full", "PGSSLROOTCERT": "/certs/ca.crt"},
                             volumes=["./labs:/labs:ro", "./scripts:/course-scripts:ro",
                                      "./versions.json:/etc/course-versions.json:ro"] + certs)
    write(home / "config/restore/restore_hba.conf", "local all all trust\nhostssl all all all scram-sha-256\n")
    services["restore"] = dict(common, profiles=["restore"], restart="no", command=["restore"], mem_limit="384m",
                               environment={"PGDATA": PGDATA},
                               ports=["${BIND_ADDRESS}:5435:5432"],
                               volumes=["./data/restore:/var/lib/postgresql", "./config/restore:/etc/course:ro",
                                        "./config/pg1/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro",
                                        "./backups:/var/lib/pgbackrest", "./logs/restore:/var/log/course"] + certs)
    for i in (1, 2):
        name = f"exporter{i}"
        services[name] = dict(common, profiles=["monitoring"], command=["exporter"], mem_limit="96m",
                             environment={"DATA_SOURCE_NAME": f"postgresql://course_monitor:${{MONITOR_PASSWORD}}@pg{i}:5432/course?sslmode=verify-full&sslrootcert=/certs/ca.crt"},
                             tmpfs=["/var/lib/postgresql:size=1m", "/tmp:size=16m"],
                             volumes=[f"./logs/{name}:/var/log/course"] + certs)
    dump("config/prometheus/prometheus.json", {
        "global": {"scrape_interval": "15s"},
        "scrape_configs": [
            {"job_name": "postgres", "static_configs": [{"targets": ["exporter1:9187", "exporter2:9187"]}]},
            {"job_name": "patroni", "static_configs": [{"targets": ["pg1:8008", "pg2:8008"]}]},
        ],
    })
    services["prometheus"] = {
        "image": VERSIONS["prometheus_image"], "profiles": ["monitoring"], "restart": "unless-stopped",
        "user": "65534:65534", "mem_limit": "192m", "cpus": 0.4, "logging": logs, "networks": ["course"],
        "ports": ["${BIND_ADDRESS}:9090:9090"],
        "entrypoint": ["/bin/sh", "-c"],
        "command": ["exec /bin/prometheus --config.file=/etc/prometheus/prometheus.json --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=24h --storage.tsdb.retention.size=128MB >> /logs/service.log 2>&1"],
        "volumes": ["./config/prometheus:/etc/prometheus:ro", "./data/prometheus:/prometheus", "./logs/prometheus:/logs"],
    }
    dump("config/grafana/provisioning/datasources/course.yaml", {
        "apiVersion": 1, "datasources": [{"name": "PostgreSQL course", "uid": "course-prometheus", "type": "prometheus",
                                         "access": "proxy", "url": "http://prometheus:9090", "isDefault": True}],
    })
    dump("config/grafana/provisioning/dashboards/course.yaml", {
        "apiVersion": 1, "providers": [{"name": "Курс PostgreSQL", "type": "file", "options": {"path": "/var/lib/grafana/dashboards"}}],
    })
    panels = []
    for number, (title, expression) in enumerate([
        ("Доступность PostgreSQL", "pg_up"),
        ("Соединения", "sum by (instance) (pg_stat_activity_count)"),
        ("Размер базы, байт", 'pg_database_size_bytes{datname="course"}'),
        ("Роль primary", "patroni_primary"),
    ], 1):
        panels.append({"id": number, "title": title, "type": "timeseries", "datasource": {"type": "prometheus", "uid": "course-prometheus"},
                       "gridPos": {"h": 8, "w": 12, "x": ((number-1) % 2)*12, "y": ((number-1)//2)*8},
                       "targets": [{"expr": expression, "refId": "A", "legendFormat": "{{instance}}"}]})
    dump("config/grafana/dashboards/course.json", {"uid": "pg-course", "title": "Учебный стенд PostgreSQL", "schemaVersion": 39,
                                                  "version": 1, "refresh": "15s", "time": {"from": "now-30m", "to": "now"}, "panels": panels})
    services["grafana"] = {
        "image": VERSIONS["grafana_image"], "profiles": ["monitoring"], "restart": "unless-stopped",
        "stop_grace_period": "30s",
        "user": "472:472", "mem_limit": "384m", "memswap_limit": "512m", "cpus": 0.4, "logging": logs, "networks": ["course"],
        "ports": ["${BIND_ADDRESS}:3000:3000"],
        "environment": {"GF_SECURITY_ADMIN_USER": "admin", "GF_SECURITY_ADMIN_PASSWORD": "${GRAFANA_PASSWORD}",
                        "GF_USERS_ALLOW_SIGN_UP": "false", "GF_ANALYTICS_REPORTING_ENABLED": "false",
                        "GF_ANALYTICS_CHECK_FOR_UPDATES": "false", "GF_LOG_MODE": "console",
                        "GF_PLUGINS_PREINSTALL_DISABLED": "true", "GF_PLUGINS_PREINSTALL_AUTO_UPDATE": "false"},
        "entrypoint": ["/bin/sh", "-c"], "command": ["exec /run.sh >> /logs/service.log 2>&1"],
        "volumes": ["./data/grafana:/var/lib/grafana", "./config/grafana/provisioning:/etc/grafana/provisioning:ro",
                    "./config/grafana/dashboards:/var/lib/grafana/dashboards:ro", "./logs/grafana:/logs"],
    }
    dump("compose.json", {"name": "pgcourse", "services": services, "networks": {"course": {"driver": "bridge"}}})
    address = values["BIND_ADDRESS"]
    sans = "DNS:localhost,DNS:master3,DNS:pg1,DNS:pg2,DNS:rw,DNS:pool,DNS:restore,IP:127.0.0.1,IP:192.168.0.35"
    if address not in ("127.0.0.1", "0.0.0.0", "192.168.0.35"):
        sans += f",IP:{address}"
    write(home / "certs/server.ext", f"subjectAltName={sans}\nextendedKeyUsage=serverAuth\n")
    write(home / "generated/pg-course-logrotate", f"""{home}/logs/*/service.log {home}/logs/pg*/pgbackrest/*.log {{
    daily
    rotate 7
    maxage 7
    compress
    missingok
    ifempty
    copytruncate
    su root root
}}
""")
    write(home / "generated/pg-course-housekeeping.service", f"""[Unit]
Description=Ротация журналов учебного стенда PostgreSQL
[Service]
Type=oneshot
ExecStart={home}/bin/labctl housekeeping
""")
    write(home / "generated/pg-course-housekeeping.timer", """[Unit]
Description=Ежедневная ротация журналов учебного стенда PostgreSQL
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
""")


def prepare_directories(home, permissions=True):
    if permissions:
        for tree in ("config", "labs", "scripts"):
            root = home / tree
            os.chmod(root, 0o755)
            for directory in root.rglob("*"):
                if directory.is_dir():
                    os.chmod(directory, 0o755)
    for name in ("pg1", "pg2", "restore", "etcd1", "etcd2", "etcd3", "prometheus", "grafana"):
        path = home / "data" / name
        path.mkdir(parents=True, exist_ok=True)
        if permissions:
            uid = 1000 if name.startswith("etcd") else 65534 if name == "prometheus" else 472 if name == "grafana" else 999
            os.chown(path, uid, uid)
            os.chmod(path, 0o700)
    for name in ("pg1", "pg2", "restore", "rw", "pool", "exporter1", "exporter2", "etcd1", "etcd2", "etcd3", "prometheus", "grafana"):
        path = home / "logs" / name
        path.mkdir(parents=True, exist_ok=True)
        if permissions:
            uid = 1000 if name.startswith("etcd") else 65534 if name == "prometheus" else 472 if name == "grafana" else 999
            os.chown(path, uid, uid)
            os.chmod(path, 0o750)
    for name in ("backups", "certs", "state", "logs/install", "logs/commands"):
        (home / name).mkdir(parents=True, exist_ok=True)
    if permissions:
        os.chmod(home, 0o700)
        os.chown(home / "backups", 999, 999)
        os.chmod(home / "backups", 0o770)


def install(source, home, bind=None, orders=None, permissions=True):
    home.mkdir(parents=True, exist_ok=True)
    values = settings(home, bind, orders)
    for directory in ("image", "scripts", "bin", "labs"):
        for path in (source / directory).rglob("*"):
            if path.is_file() and "__pycache__" not in path.parts:
                destination = home / path.relative_to(source)
                if path.resolve() != destination.resolve():
                    write(destination, path.read_text(encoding="utf-8"), 0o755 if path.suffix == ".sh" or directory == "bin" else 0o644)
    for filename in ("install.sh", "README.md", "versions.json"):
        path = source / filename
        if path.exists() and path.resolve() != (home / filename).resolve():
            write(home / filename, path.read_text(encoding="utf-8"), 0o755 if filename.endswith(".sh") else 0o644)
    generate(home, values)
    prepare_directories(home, permissions)
    print(f"Конфигурация подготовлена: {home}. Секреты и данные сохранены.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--bind-address")
    parser.add_argument("--orders", type=int)
    parser.add_argument("--no-permissions", action="store_true", help="Для локальной проверки генератора без chown")
    args = parser.parse_args()
    try:
        install(args.source.resolve(), args.home.resolve(), args.bind_address, args.orders, not args.no_permissions)
    except (ValueError, KeyError) as error:
        parser.exit(1, f"Ошибка конфигурации: {error}\n")
