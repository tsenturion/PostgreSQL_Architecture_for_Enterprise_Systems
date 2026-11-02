# WAL, контрольные точки, механизмы восстановления и базовые принципы отказоустойчивости

## Введение

## WAL и порядок сохранения изменений

[русской документации WAL](https://postgrespro.ru/docs/postgresql/18/wal-intro)

```sql
SELECT pg_current_wal_insert_lsn() AS insert_lsn,
       pg_current_wal_lsn() AS write_lsn,
       pg_current_wal_flush_lsn() AS flush_lsn,
       current_setting('wal_level') AS wal_level;
```

```sql
CREATE TABLE IF NOT EXISTS lab.wal_demo (
    probe_id integer PRIMARY KEY,
    payload text NOT NULL
);
INSERT INTO lab.wal_demo(probe_id, payload)
VALUES (1, 'Исходное состояние')
ON CONFLICT (probe_id) DO UPDATE SET payload = EXCLUDED.payload;
SELECT set_config(
    'lecture03.start_lsn',
    pg_current_wal_insert_lsn()::text,
    false
) AS start_lsn;
```

```sql
BEGIN;
UPDATE lab.wal_demo
SET payload = 'Отменяемое изменение'
WHERE probe_id = 1;
ROLLBACK;
SELECT payload,
       pg_wal_lsn_diff(
           pg_current_wal_insert_lsn(),
           current_setting('lecture03.start_lsn')::pg_lsn
       ) AS wal_bytes_since_mark
FROM lab.wal_demo WHERE probe_id = 1;
```

[русской документации непрерывного архивирования](https://postgrespro.ru/docs/postgresql/18/continuous-archiving)

## Контрольные точки

[русской документации о контрольных данных](https://postgrespro.ru/docs/postgresql/18/functions-info#FUNCTIONS-CONTROLDATA)

```sql
SELECT checkpoint_lsn,
       redo_lsn,
       redo_wal_file,
       timeline_id,
       checkpoint_time
FROM pg_control_checkpoint();
```

[русской документации CHECKPOINT](https://postgrespro.ru/docs/postgresql/18/sql-checkpoint)

```sql
UPDATE lab.wal_demo
SET payload = 'Состояние перед контрольной точкой'
WHERE probe_id = 1;
CHECKPOINT;
SELECT checkpoint_lsn, redo_lsn, checkpoint_time
FROM pg_control_checkpoint();
```

[русской документации конфигурации WAL](https://postgrespro.ru/docs/postgresql/18/wal-configuration)

```sql
SELECT current_setting('full_page_writes') AS full_page_writes,
       w.wal_fpi,
       w.wal_bytes,
       c.num_done AS completed_checkpoints,
       c.buffers_written
FROM pg_stat_wal AS w
CROSS JOIN pg_stat_checkpointer AS c;
```

## Механизмы восстановления

```bash
install -d -o 999 -g 999 -m 0700 /opt/pg-course/data/wal-demo
install -d -o 999 -g 999 -m 0750 /opt/pg-course/logs/wal-demo
docker run -d --name pgcourse-wal-demo --pull=never --restart=no \
  --label pg-course.lesson=wal --network none --log-driver none \
  --memory 256m --cpus 0.5 --shm-size 64m --user 999:999 \
  --mount type=bind,src=/opt/pg-course/data/wal-demo,dst=/var/lib/postgresql \
  --mount type=bind,src=/opt/pg-course/logs/wal-demo,dst=/var/log/course \
  --env PGDATA=/var/lib/postgresql/18/docker \
  --entrypoint /bin/sh pg-course-local:18 -c '
    exec >>/var/log/course/service.log 2>&1
    if [ ! -s "$PGDATA/PG_VERSION" ]; then
      initdb -D "$PGDATA" -U postgres \
        --auth-local=trust --auth-host=scram-sha-256 \
        --encoding=UTF8 --locale=C.UTF-8
    fi
    exec postgres -D "$PGDATA" \
      -c listen_addresses= -c unix_socket_directories=/tmp \
      -c shared_buffers=16MB -c max_connections=10 \
      -c max_wal_size=64MB -c min_wal_size=32MB \
      -c checkpoint_timeout=30min -c log_checkpoints=on
  '
for attempt in $(seq 1 30); do
  if docker exec --user postgres pgcourse-wal-demo \
       pg_isready -q -h /tmp -U postgres -d postgres; then
    break
  fi
  sleep 1
done
docker exec --user postgres pgcourse-wal-demo \
  pg_isready -h /tmp -U postgres -d postgres
```

[русской документации psql](https://postgrespro.ru/docs/postgresql/18/app-psql)

```bash
docker exec -i --user postgres pgcourse-wal-demo \
  psql -X -h /tmp -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
DROP TABLE IF EXISTS public.recovery_probe;
CREATE TABLE public.recovery_probe (
    probe_id integer PRIMARY KEY,
    payload text NOT NULL
);
INSERT INTO public.recovery_probe VALUES (1, 'До контрольной точки');
CHECKPOINT;
INSERT INTO public.recovery_probe VALUES (2, 'После контрольной точки');
SELECT probe_id, payload FROM public.recovery_probe ORDER BY probe_id;
SQL
```

```bash
docker exec -d --user postgres --env PGAPPNAME=wal-uncommitted \
  pgcourse-wal-demo psql -X -h /tmp -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -c \
  "BEGIN; INSERT INTO public.recovery_probe VALUES (3, 'Открытая транзакция'); SELECT pg_sleep(900);"
for attempt in $(seq 1 30); do
  ready=$(docker exec --user postgres pgcourse-wal-demo \
    psql -X -h /tmp -U postgres -d postgres -Atc \
    "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'wal-uncommitted' AND wait_event = 'PgSleep');")
  if [ "$ready" = t ]; then
    break
  fi
  sleep 1
done
test "$ready" = t
printf '%s\n' "$ready"
```

```bash
docker kill --signal KILL pgcourse-wal-demo
```

```bash
docker start pgcourse-wal-demo
for attempt in $(seq 1 30); do
  if docker exec --user postgres pgcourse-wal-demo \
       pg_isready -q -h /tmp -U postgres -d postgres; then
    break
  fi
  sleep 1
done
docker exec --user postgres pgcourse-wal-demo \
  psql -X -h /tmp -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c 'SELECT probe_id, payload FROM public.recovery_probe ORDER BY probe_id; SELECT NOT pg_is_in_recovery() AS recovery_finished;'
```

[русской документации управления сервером](https://postgrespro.ru/docs/postgresql/18/server-start)

[русской документации архивного восстановления](https://postgrespro.ru/docs/postgresql/18/continuous-archiving)

```sql
SELECT archived_count,
       last_archived_wal,
       last_archived_time,
       failed_count,
       last_failed_wal,
       last_failed_time
FROM pg_stat_archiver;
```

[русской документации PostgreSQL](https://postgrespro.ru/docs/postgresql/18/server-shutdown)

```bash
docker stop --signal SIGINT --timeout 30 pgcourse-wal-demo
docker rm pgcourse-wal-demo
```

## Базовые принципы отказоустойчивости

[русской документации PostgreSQL](https://postgrespro.ru/docs/postgresql/18/warm-standby#STANDBY-SERVER-OPERATION)

```sql
SELECT inet_server_addr() AS server_address,
       inet_server_port() AS server_port,
       pg_is_in_recovery() AS in_recovery;
```

[русской документации потоковой репликации](https://postgrespro.ru/docs/postgresql/18/warm-standby#STREAMING-REPLICATION)

```sql
SELECT application_name,
       state,
       sync_state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS apply_gap_bytes
FROM pg_stat_replication;
```

[правилами лидерства Patroni](https://patroni.readthedocs.io/en/latest/ha_multi_dc.html)

## Заключение
