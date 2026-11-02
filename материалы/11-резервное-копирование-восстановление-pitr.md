# Стратегии резервного копирования и восстановления: физическое, логическое, PITR и проверка результата

## Введение

## Состав копии и подготовка контрольных данных

```bash
(
set -eu
cd /opt/pg-course
for name in pgcourse-physical11 pgcourse-pitr11; do
  if docker container inspect "$name" >/dev/null 2>&1; then
    printf 'Контейнер %s уже существует.\n' "$name" >&2
    exit 1
  fi
done
for path in data/physical11 data/pitr11 backups/lecture11 state/lecture11; do
  test ! -e "$path" || { printf 'Путь %s уже существует.\n' "$path" >&2; exit 1; }
done
available=$(df -B1 --output=avail /opt/pg-course | tail -n 1)
test "$available" -ge 2147483648
PGCOURSE_NODE=
for node in pg1 pg2; do
  if test "$(docker compose -f compose.json exec -T -u postgres "$node" \
    psql -XAt -h /var/run/postgresql -U postgres -d course \
    -c 'SELECT NOT pg_is_in_recovery()')" = t; then
    PGCOURSE_NODE=$node
    break
  fi
done
test -n "$PGCOURSE_NODE"
install -d -m 0700 state/lecture11
install -d -o 999 -g 999 -m 0700 backups/lecture11
install -d -o 999 -g 999 -m 0700 data/physical11 data/pitr11
install -d -o 999 -g 999 -m 0750 logs/pg-physical11/pgbackrest logs/pg-pitr11/pgbackrest
printf 'PGCOURSE_NODE=%s\n' "$PGCOURSE_NODE" > state/lecture11/session.env
chmod 0600 state/lecture11/session.env
printf 'Исходный primary: %s\n' "$PGCOURSE_NODE"
du -sh "data/$PGCOURSE_NODE" backups/repo
)
```

```sql
BEGIN;
SET LOCAL ROLE course_owner;
CREATE SCHEMA backup11 AUTHORIZATION course_owner;
CREATE TABLE backup11.orders (
    order_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer text NOT NULL,
    total_amount numeric(12,2) NOT NULL CHECK (total_amount >= 0),
    state text NOT NULL DEFAULT 'new' CHECK (state IN ('new', 'paid'))
);
CREATE TABLE backup11.order_items (
    order_id bigint NOT NULL REFERENCES backup11.orders(order_id),
    line_no integer NOT NULL,
    qty integer NOT NULL CHECK (qty > 0),
    unit_price numeric(12,2) NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (order_id, line_no)
);
INSERT INTO backup11.orders(customer, total_amount)
VALUES ('Компания Альфа', 300), ('Компания Бета', 150);
INSERT INTO backup11.order_items VALUES
    (1, 1, 2, 100), (1, 2, 1, 100), (2, 1, 1, 150);
CREATE VIEW backup11.recovery_check AS
SELECT (SELECT count(*) FROM backup11.orders) AS orders,
       (SELECT count(*) FROM backup11.order_items) AS items,
       (SELECT sum(total_amount) FROM backup11.orders) AS order_total,
       (SELECT sum(qty * unit_price) FROM backup11.order_items) AS item_total,
       (SELECT count(*) FROM backup11.orders o
        WHERE o.total_amount IS DISTINCT FROM
              (SELECT sum(i.qty * i.unit_price)
               FROM backup11.order_items i WHERE i.order_id = o.order_id)) AS mismatches,
       (SELECT state FROM backup11.orders WHERE order_id = 1) AS first_state;
COMMIT;
SELECT * FROM backup11.recovery_check;
```

[разделе о непрерывном архивировании PostgreSQL](https://postgrespro.ru/docs/postgresql/18/continuous-archiving)

## Полная, дифференциальная и инкрементальная физическая копия

[руководстве pgBackRest](https://pgbackrest.org/user-guide.html#backup)

```bash
(
set -eu
cd /opt/pg-course
. state/lecture11/session.env
test "$(docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  psql -XAt -h /var/run/postgresql -U postgres -d course \
  -c 'SELECT NOT pg_is_in_recovery()')" = t
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pgbackrest --stanza=course --type=full --expire-auto=n \
  --annotation=lesson=lecture11 backup
FULL_SET=$(docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pgbackrest --stanza=course --output=json info | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["backup"][-1]["label"])')
printf 'FULL_SET=%s\n' "$FULL_SET" >> state/lecture11/session.env
printf 'Полная копия: %s\n' "$FULL_SET"
)
```

```sql
BEGIN;
INSERT INTO backup11.orders(customer, total_amount)
VALUES ('Компания Гамма', 200);
INSERT INTO backup11.order_items VALUES (3, 1, 2, 100);
COMMIT;
SELECT * FROM backup11.recovery_check;
```

```bash
(
set -eu
cd /opt/pg-course
. state/lecture11/session.env
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pgbackrest --stanza=course --type=diff --expire-auto=n \
  --annotation=lesson=lecture11 backup
DIFF_SET=$(docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pgbackrest --stanza=course --output=json info | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["backup"][-1]["label"])')
printf 'DIFF_SET=%s\n' "$DIFF_SET" >> state/lecture11/session.env
printf 'Дифференциальная копия: %s\n' "$DIFF_SET"
)
```

```sql
UPDATE backup11.orders SET state = 'paid' WHERE order_id = 1;
SELECT * FROM backup11.recovery_check;
```

```bash
(
set -eu
cd /opt/pg-course
. state/lecture11/session.env
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pgbackrest --stanza=course --type=incr --expire-auto=n \
  --annotation=lesson=lecture11 backup
INCR_SET=$(docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pgbackrest --stanza=course --output=json info | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["backup"][-1]["label"])')
printf 'INCR_SET=%s\n' "$INCR_SET" >> state/lecture11/session.env
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pgbackrest --stanza=course --set="$INCR_SET" info
)
```

## Логическая выгрузка и состав архива

[документации `pg_dump`](https://postgrespro.ru/docs/postgresql/18/app-pgdump)

[документации `pg_dumpall`](https://postgrespro.ru/docs/postgresql/18/app-pg-dumpall)

```bash
(
set -eu
cd /opt/pg-course
. state/lecture11/session.env
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pg_dump -h /var/run/postgresql -U postgres -d course --format=custom \
  --schema=backup11 --file=/var/lib/pgbackrest/lecture11/backup11.dump \
  2>> logs/pg-physical11/service.log
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pg_dumpall -h /var/run/postgresql -U postgres --globals-only --no-role-passwords \
  --file=/var/lib/pgbackrest/lecture11/globals.sql \
  2>> logs/pg-physical11/service.log
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pg_restore --list /var/lib/pgbackrest/lecture11/backup11.dump \
  > backups/lecture11/contents.list
chmod 0600 backups/lecture11/contents.list
printf '%s lecture11: логические архивы созданы\n' "$(date -u +%FT%TZ)" \
  >> logs/pg-physical11/service.log
)
```

[документации `pg_restore`](https://postgrespro.ru/docs/postgresql/18/app-pgrestore)

## Физическое восстановление выбранного набора

[справочнике команды `restore` pgBackRest](https://pgbackrest.org/command.html#command-restore)

```bash
(
set -eu
cd /opt/pg-course
. state/lecture11/session.env
docker run --rm --name pgcourse-restore11-job --pull=never \
  --network none --log-driver none --user 999:999 --memory 192m --cpus 0.5 \
  --mount type=bind,src=/opt/pg-course/data/physical11,dst=/var/lib/postgresql \
  --mount type=bind,src=/opt/pg-course/backups,dst=/var/lib/pgbackrest \
  --mount type=bind,src=/opt/pg-course/config/pg1/pgbackrest.conf,dst=/etc/pgbackrest/pgbackrest.conf,readonly \
  --mount type=bind,src=/opt/pg-course/logs/pg-physical11,dst=/var/log/course \
  --entrypoint pgbackrest pg-course-local:18 \
  --stanza=course --set="$INCR_SET" --pg1-path=/var/lib/postgresql/18/docker \
  --archive-mode=off --type=immediate --target-action=promote \
  --recovery-option='restore_command=pgbackrest --stanza=course archive-get %f "%p"' restore
)
```

```bash
(
set -eu
docker run -d --name pgcourse-physical11 --pull=never --restart=no \
  --label pg-course.lesson=backup11 --network pgcourse_course --log-driver none \
  --memory 384m --memory-swap 384m --cpus 0.5 --shm-size 128m \
  -p 5436:5432 -e PGDATA=/var/lib/postgresql/18/docker \
  --mount type=bind,src=/opt/pg-course/data/physical11,dst=/var/lib/postgresql \
  --mount type=bind,src=/opt/pg-course/backups,dst=/var/lib/pgbackrest \
  --mount type=bind,src=/opt/pg-course/config/restore,dst=/etc/course,readonly \
  --mount type=bind,src=/opt/pg-course/config/pg1/pgbackrest.conf,dst=/etc/pgbackrest/pgbackrest.conf,readonly \
  --mount type=bind,src=/opt/pg-course/logs/pg-physical11,dst=/var/log/course \
  --mount type=bind,src=/opt/pg-course/certs/ca.crt,dst=/certs/ca.crt,readonly \
  --mount type=bind,src=/opt/pg-course/certs/server.crt,dst=/certs/server.crt,readonly \
  --mount type=bind,src=/opt/pg-course/certs/server.key,dst=/certs/server.key,readonly \
  pg-course-local:18 restore
for attempt in $(seq 1 60); do
  if test "$(docker exec -u postgres pgcourse-physical11 \
    psql -XAt -h /var/run/postgresql -U postgres -d course \
    -c 'SELECT NOT pg_is_in_recovery()' 2>/dev/null)" = t; then
    printf 'Физический экземпляр готов на порту 5436.\n'
    exit 0
  fi
  sleep 1
done
printf 'Проверьте /opt/pg-course/logs/pg-physical11/service.log\n' >&2
exit 1
)
```

```sql
SELECT current_database() AS database_name,
       pg_is_in_recovery() AS in_recovery, c.*
FROM backup11.recovery_check c;
```

## Логическое восстановление и проверка объектов

```bash
(
set -eu
cd /opt/pg-course
docker exec -u postgres pgcourse-physical11 \
  createdb -h /var/run/postgresql -U postgres --template=template0 logical11
docker exec -u postgres pgcourse-physical11 \
  pg_restore -h /var/run/postgresql -U postgres -d logical11 \
  --no-owner --no-privileges --exit-on-error --single-transaction \
  /var/lib/pgbackrest/lecture11/backup11.dump \
  2>> logs/pg-physical11/service.log
docker exec -u postgres pgcourse-physical11 \
  vacuumdb -h /var/run/postgresql -U postgres -d logical11 --analyze-only \
  >> logs/pg-physical11/service.log 2>&1
printf '%s lecture11: logical11 восстановлена\n' "$(date -u +%FT%TZ)" \
  >> logs/pg-physical11/service.log
)
```

```sql
SELECT current_database() AS database_name,
       pg_get_userbyid((SELECT relowner FROM pg_class
                       WHERE oid = 'backup11.orders'::regclass)) AS table_owner,
       c.*
FROM backup11.recovery_check c;
```

```sql
INSERT INTO backup11.order_items(order_id, line_no, qty, unit_price)
VALUES (999, 1, 1, 10);
```

```sql
BEGIN;
INSERT INTO backup11.orders(customer, total_amount)
VALUES ('Проверка восстановления', 0)
RETURNING order_id;
ROLLBACK;
```

## PITR: выбор границы и восстановление перед ошибкой

```sql
BEGIN;
INSERT INTO backup11.orders(customer, total_amount)
VALUES ('Компания Дельта', 250);
INSERT INTO backup11.order_items VALUES (4, 1, 1, 250);
COMMIT;
SELECT * FROM backup11.recovery_check;
```

[параметрах цели восстановления PostgreSQL](https://postgrespro.ru/docs/postgresql/18/runtime-config-wal#RUNTIME-CONFIG-WAL-RECOVERY-TARGET)

```bash
(
set -eu
cd /opt/pg-course
. state/lecture11/session.env
PITR_TARGET=$(docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  psql -XAt -h /var/run/postgresql -U postgres -d course \
  -c "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00'")
printf 'PITR_TARGET=%q\n' "$PITR_TARGET" >> state/lecture11/session.env
printf 'Цель PITR: %s\n' "$PITR_TARGET"
)
```

```sql
UPDATE backup11.orders SET total_amount = 0;
SELECT * FROM backup11.recovery_check;
```

```bash
(
set -eu
cd /opt/pg-course
. state/lecture11/session.env
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  psql -X -v ON_ERROR_STOP=1 -h /var/run/postgresql -U postgres -d course \
  -c 'SELECT pg_switch_wal();'
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pgbackrest --stanza=course check
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  psql -X -h /var/run/postgresql -U postgres -d course \
  -c 'SELECT archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_time FROM pg_stat_archiver;'
)
```

```bash
(
set -eu
cd /opt/pg-course
. state/lecture11/session.env
docker run --rm --name pgcourse-restore11-job --pull=never \
  --network none --log-driver none --user 999:999 --memory 192m --cpus 0.5 \
  --mount type=bind,src=/opt/pg-course/data/pitr11,dst=/var/lib/postgresql \
  --mount type=bind,src=/opt/pg-course/backups,dst=/var/lib/pgbackrest \
  --mount type=bind,src=/opt/pg-course/config/pg1/pgbackrest.conf,dst=/etc/pgbackrest/pgbackrest.conf,readonly \
  --mount type=bind,src=/opt/pg-course/logs/pg-pitr11,dst=/var/log/course \
  --entrypoint pgbackrest pg-course-local:18 \
  --stanza=course --set="$INCR_SET" --pg1-path=/var/lib/postgresql/18/docker \
  --archive-mode=off --type=time --target="$PITR_TARGET" --target-action=promote \
  --recovery-option='restore_command=pgbackrest --stanza=course archive-get %f "%p"' restore
)
```

```bash
(
set -eu
docker run -d --name pgcourse-pitr11 --pull=never --restart=no \
  --label pg-course.lesson=backup11 --network pgcourse_course --log-driver none \
  --memory 384m --memory-swap 384m --cpus 0.5 --shm-size 128m \
  -p 5437:5432 -e PGDATA=/var/lib/postgresql/18/docker \
  --mount type=bind,src=/opt/pg-course/data/pitr11,dst=/var/lib/postgresql \
  --mount type=bind,src=/opt/pg-course/backups,dst=/var/lib/pgbackrest \
  --mount type=bind,src=/opt/pg-course/config/restore,dst=/etc/course,readonly \
  --mount type=bind,src=/opt/pg-course/config/pg1/pgbackrest.conf,dst=/etc/pgbackrest/pgbackrest.conf,readonly \
  --mount type=bind,src=/opt/pg-course/logs/pg-pitr11,dst=/var/log/course \
  --mount type=bind,src=/opt/pg-course/certs/ca.crt,dst=/certs/ca.crt,readonly \
  --mount type=bind,src=/opt/pg-course/certs/server.crt,dst=/certs/server.crt,readonly \
  --mount type=bind,src=/opt/pg-course/certs/server.key,dst=/certs/server.key,readonly \
  pg-course-local:18 restore
for attempt in $(seq 1 60); do
  if test "$(docker exec -u postgres pgcourse-pitr11 \
    psql -XAt -h /var/run/postgresql -U postgres -d course \
    -c 'SELECT NOT pg_is_in_recovery()' 2>/dev/null)" = t; then
    printf 'PITR-экземпляр готов на порту 5437.\n'
    exit 0
  fi
  sleep 1
done
printf 'Проверьте /opt/pg-course/logs/pg-pitr11/service.log\n' >&2
exit 1
)
```

```sql
SELECT current_database() AS database_name,
       pg_is_in_recovery() AS in_recovery, c.*
FROM backup11.recovery_check c;
```

## Регулярная проверка восстановления и удержание копий

[справочнике `expire` pgBackRest](https://pgbackrest.org/command.html#command-expire)

```bash
(
set -eu
cd /opt/pg-course
. state/lecture11/session.env
docker compose -f compose.json exec -T -u postgres "$PGCOURSE_NODE" \
  pgbackrest --stanza=course --dry-run expire
)
```

```sql
DROP SCHEMA backup11 CASCADE;
```

```bash
python3 - <<'PY'
from pathlib import Path
import json
import shutil
import subprocess

root = Path('/opt/pg-course').resolve(strict=True)
for name in ('pgcourse-physical11', 'pgcourse-pitr11'):
    info = json.loads(subprocess.check_output(['docker', 'inspect', name]))[0]
    assert info['Config']['Labels'].get('pg-course.lesson') == 'backup11', name
    subprocess.run(['docker', 'stop', '--signal', 'SIGINT', '--timeout', '60', name], check=True)
    state = json.loads(subprocess.check_output(['docker', 'inspect', name]))[0]['State']
    assert state['ExitCode'] == 0 and not state['OOMKilled'], state
    subprocess.run(['docker', 'rm', name], check=True)

for relative in ('data/physical11', 'data/pitr11', 'backups/lecture11', 'state/lecture11'):
    target = root / relative
    assert not target.is_symlink(), target
    assert target.resolve(strict=True) == root / relative, target
    assert root in target.resolve().parents, target
    shutil.rmtree(target)
print('Учебные экземпляры и рабочие каталоги удалены; журналы и наборы копий сохранены.')
PY
```

## Заключение
