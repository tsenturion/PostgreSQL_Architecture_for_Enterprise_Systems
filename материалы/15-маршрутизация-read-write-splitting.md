# Взаимодействие с приложениями и балансировщиками нагрузки

## Как балансировщик выбирает сервер

[REST API Patroni](https://patroni.readthedocs.io/en/latest/rest_api.html)

```sql
SELECT inet_server_addr() AS server_address,
       pg_backend_pid() AS backend_pid,
       pg_is_in_recovery() AS in_recovery,
       current_setting('transaction_read_only') AS transaction_read_only;
```

[Руководство HAProxy](https://docs.haproxy.org/3.4/configuration.html)

## Выделенный маршрут чтения

```bash
bash -euo pipefail <<'BASH'
dir=/opt/pg-course/generated/routing15
image=$(docker inspect pgcourse-rw-1 --format '{{.Config.Image}}')
mkdir "$dir"
cat > "$dir/haproxy.cfg" <<'CFG'
defaults
    mode tcp
    timeout connect 3s
    timeout client 2m
    timeout server 2m
    timeout check 2s

resolvers docker_dns
    nameserver docker 127.0.0.11:53
    hold valid 5s

frontend postgres_read
    bind *:5432
    default_backend postgres_replicas

backend postgres_replicas
    balance leastconn
    option httpchk GET /replica?lag=1MB
    http-check expect status 200
    default-server inter 2s fall 2 rise 2 on-marked-down shutdown-sessions
    server pg1 pg1:5432 check port 8008 resolvers docker_dns resolve-prefer ipv4 init-addr last,libc,none
    server pg2 pg2:5432 check port 8008 resolvers docker_dns resolve-prefer ipv4 init-addr last,libc,none
CFG
mount="type=bind,src=$dir/haproxy.cfg,dst=/usr/local/etc/haproxy/haproxy.cfg,readonly"
docker run --rm --pull never --network pgcourse_course --mount "$mount" \
  "$image" haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
docker run -d --pull never --name pg-course-routing15 \
  --label pg-course.lesson=15 --network pgcourse_course \
  --memory 64m --memory-swap 64m --cpus 0.25 \
  --log-driver local --log-opt max-size=1m --log-opt max-file=2 \
  -p 192.168.0.35:5438:5432 --mount "$mount" "$image"
BASH
```

[Проверки Patroni](https://patroni.readthedocs.io/en/latest/rest_api.html#health-check-endpoints)

```sql
SELECT inet_server_addr() AS server_address,
       pg_is_in_recovery() AS in_recovery,
       current_setting('transaction_read_only') AS transaction_read_only,
       pg_last_wal_replay_lsn() AS replay_lsn;
```

[Функции PostgreSQL](https://postgrespro.ru/docs/postgresql/18/functions-admin)

```bash
cd /opt/pg-course
docker compose -f compose.json exec -T pool sh -ec '
  conninfo="host=pg1,pg2 port=5432 dbname=course user=postgres sslmode=verify-full sslrootcert=/certs/ca.crt connect_timeout=3 target_session_attrs=standby"
  query="SELECT inet_server_addr() AS server_address, pg_is_in_recovery() AS in_recovery;"
  PGPASSWORD="$POSTGRES_PASSWORD" psql -X -v ON_ERROR_STOP=1 "$conninfo" -c "$query"
'
```

[Параметры подключения libpq](https://postgrespro.ru/docs/postgresql/18/libpq-connect)

## Разделение операций и чтение после записи

```sql
BEGIN;
CREATE SCHEMA IF NOT EXISTS routing15;
CREATE TABLE IF NOT EXISTS routing15.orders (
    order_id bigint PRIMARY KEY,
    status text NOT NULL,
    version bigint NOT NULL
);
INSERT INTO routing15.orders AS o (order_id, status, version)
VALUES (42, 'confirmed', 1)
ON CONFLICT (order_id) DO UPDATE
SET status = EXCLUDED.status, version = o.version + 1
RETURNING order_id, status, version;
COMMIT;
SELECT pg_current_wal_insert_lsn() AS required_lsn;
```

```sql
WITH replay AS MATERIALIZED (
    SELECT pg_is_in_recovery() AS on_replica,
           pg_last_wal_replay_lsn() AS replay_lsn
)
SELECT replay_lsn,
       CASE
           WHEN on_replica AND replay_lsn >= CAST(:required_lsn AS pg_lsn)
               THEN 'read_on_replica'
           ELSE 'use_primary'
       END AS decision
FROM replay;
```

```sql
SELECT order_id, status, version
FROM routing15.orders
WHERE order_id = 42;
```

## Завершение работы с учебными маршрутами

```sql
DROP TABLE IF EXISTS routing15.orders;
DROP SCHEMA IF EXISTS routing15;
```

```bash
bash -euo pipefail <<'BASH'
name=pg-course-routing15
dir=/opt/pg-course/generated/routing15
test "$(docker inspect "$name" --format '{{index .Config.Labels "pg-course.lesson"}}')" = 15
docker stop "$name"
docker rm "$name"
rm -- "$dir/haproxy.cfg"
rmdir -- "$dir"
BASH
```

## Заключение
