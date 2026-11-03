# Управление конфигурацией, автоматизация администрирования и сопровождение production-сред

## Введение

## Источник намерения и действующая конфигурация

[документации конфигурации Patroni](https://patroni.readthedocs.io/en/latest/yaml_configuration.html)

```bash
cd /opt/pg-course
docker compose -f compose.json exec -T pg1 \
  patronictl -c /etc/course/patroni.json show-config course
```

[русской документации настройки PostgreSQL](https://postgrespro.ru/docs/postgresql/18/config-setting)

```sql
SELECT name, setting, unit, source, sourcefile
FROM pg_settings
WHERE name IN ('max_connections', 'work_mem', 'log_min_duration_statement')
ORDER BY name;
```

## Управляемая область изменения

```bash
(
set -eu
cd /opt/pg-course
python3 - <<'PY'
from pathlib import Path
import os
import subprocess

root = Path('/opt/pg-course')
assert subprocess.run(['docker', 'inspect', 'pgcourse-admin14'], capture_output=True).returncode != 0
for relative in ('data/admin14', 'config/admin14', 'state/lecture14', 'generated/lecture14'):
    assert not (root / relative).exists(), relative
for name in ('pgcourse-admin14-maint.service', 'pgcourse-admin14-maint.timer'):
    assert not (Path('/etc/systemd/system') / name).exists(), name
for relative in ('config/admin14/conf.d', 'generated/lecture14'):
    (root / relative).mkdir(parents=True, mode=0o755)
(root / 'config/admin14').chmod(0o755)
(root / 'state/lecture14').mkdir(mode=0o700)
(root / 'data/admin14').mkdir(mode=0o700)
os.chown(root / 'data/admin14', 999, 999)
for name in ('admin14-db', 'admin14-controller', 'admin14-maint'):
    (root / 'logs' / name).mkdir(mode=0o750, exist_ok=True)
base = """data_directory = '/var/lib/postgresql/18/docker'
listen_addresses = '*'
port = 5432
hba_file = '/etc/course/pg_hba.conf'
ssl = on
ssl_cert_file = '/certs/server.crt'
ssl_key_file = '/certs/server.key'
max_connections = 24
max_wal_size = '128MB'
min_wal_size = '32MB'
effective_cache_size = '192MB'
logging_collector = off
log_line_prefix = '%m [admin14:%p] %u@%d app=%a '
include_dir = 'conf.d'
"""
initial = "work_mem = '2MB'\nlog_min_duration_statement = '500ms'\nshared_buffers = '64MB'\n"
(root / 'config/admin14/postgresql.conf').write_text(base)
(root / 'config/admin14/pg_hba.conf').write_text('local all all trust\nhostssl all all all scram-sha-256\n')
(root / 'config/admin14/conf.d/90-managed.conf').write_text(initial)
(root / 'state/lecture14/baseline.conf').write_text(initial)
for path in (root / 'config/admin14').rglob('*'):
    path.chmod(0o755 if path.is_dir() else 0o644)
PY
docker run -d --name pgcourse-admin14 --pull=never --restart=no \
  --label pg-course.lesson=admin14 --network pgcourse_course --log-driver none \
  --memory 384m --memory-swap 384m --cpus 0.5 --shm-size 128m \
  -p 5436:5432 -e PGDATA=/var/lib/postgresql/18/docker \
  -e POSTGRES_DB=course -e POSTGRES_PASSWORD='Admin14-admin-2026!' \
  --mount type=bind,src=/opt/pg-course/data/admin14,dst=/var/lib/postgresql \
  --mount type=bind,src=/opt/pg-course/config/admin14,dst=/etc/course,readonly \
  --mount type=bind,src=/opt/pg-course/logs/admin14-db,dst=/var/log/course \
  --mount type=bind,src=/opt/pg-course/certs/ca.crt,dst=/certs/ca.crt,readonly \
  --mount type=bind,src=/opt/pg-course/certs/server.crt,dst=/certs/server.crt,readonly \
  --mount type=bind,src=/opt/pg-course/certs/server.key,dst=/certs/server.key,readonly \
  --entrypoint /bin/bash pg-course-local:18 -c '
    install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/18 "$PGDATA"
    umask 077
    exec /usr/local/bin/docker-entrypoint.sh postgres \
      -c config_file=/etc/course/postgresql.conf >> /var/log/course/service.log 2>&1'
for attempt in $(seq 1 60); do
  if docker exec -e PGPASSWORD='Admin14-admin-2026!' pgcourse-admin14 \
    psql -XAt -h 127.0.0.1 -U postgres -d course -c 'SELECT 1' 2>/dev/null | grep -qx 1; then
    printf 'Экземпляр admin14 готов на порту 5436.\n'
    exit 0
  fi
  sleep 1
done
printf 'Проверьте /opt/pg-course/logs/admin14-db/service.log\n' >&2
exit 1
)
```

```sql
CREATE SCHEMA admin14;
CREATE TABLE admin14.events (
    event_id integer PRIMARY KEY,
    recorded_at timestamptz NOT NULL,
    payload text NOT NULL
);
INSERT INTO admin14.events
SELECT n, now() - n * interval '1 minute', 'Событие ' || n
FROM generate_series(1, 300) AS n;
CREATE TABLE admin14.job_state (
    task text PRIMARY KEY,
    row_count bigint NOT NULL,
    last_success_at timestamptz NOT NULL,
    run_count integer NOT NULL
);
CREATE ROLE admin14_job LOGIN PASSWORD 'Admin14-job-2026!';
GRANT USAGE ON SCHEMA admin14 TO admin14_job;
GRANT SELECT, MAINTAIN ON admin14.events TO admin14_job;
GRANT SELECT, INSERT, UPDATE ON admin14.job_state TO admin14_job;
SELECT name, current_setting(name) AS active_value, sourcefile
FROM pg_settings
WHERE name IN ('work_mem', 'log_min_duration_statement', 'shared_buffers')
ORDER BY name;
```

## Проверка, применение и повторный запуск

```python
from pathlib import Path
import fcntl
import json
import logging
import os
import subprocess
import sys
import tempfile
import time

os.umask(0o077)
root = Path('/opt/pg-course')
state = root / 'state/lecture14'
current = root / 'config/admin14/conf.d/90-managed.conf'
desired = root / 'generated/lecture14/desired.conf'
logging.basicConfig(filename=root / 'logs/admin14-controller/service.log', level=logging.INFO,
                    format='%(asctime)s change=CFG-014 %(message)s')

def report(status, message):
    text = f'status={status} {message}'
    logging.info(text)
    print(text, flush=True)

def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError((result.stderr + result.stdout).strip())
    return result.stdout.strip()

def sql(statement):
    return run(['docker', 'exec', '-u', 'postgres', 'pgcourse-admin14', 'psql', '-XAt',
                '-v', 'ON_ERROR_STOP=1', '-h', '/var/run/postgresql', '-U', 'postgres',
                '-d', 'course', '-c', statement])

def replace(content):
    with tempfile.NamedTemporaryFile(dir=current.parent, prefix='.managed-', suffix='.tmp', delete=False) as file:
        temporary = Path(file.name)
        os.fchmod(file.fileno(), 0o644)
        file.write(content)
        file.flush()
        os.fsync(file.fileno())
    try:
        os.replace(temporary, current)
        descriptor = os.open(current.parent, os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        temporary.unlink(missing_ok=True)

def observe(expected):
    statement = """SELECT jsonb_object_agg(name, jsonb_build_object(
        'value', setting, 'unit', unit, 'display', current_setting(name), 'pending', pending_restart))
        FROM pg_settings WHERE name IN ('work_mem','log_min_duration_statement','shared_buffers')"""
    for attempt in range(20):
        actual = json.loads(sql(statement))
        differences = [key for key in expected if actual[key]['value'] != expected[key]]
        if not differences:
            return 3 if any(row['pending'] for row in actual.values()) else 0, actual
        if all(actual[key]['pending'] for key in differences):
            return 3, actual
        time.sleep(0.2)
    return 4, actual

lock = open('/run/lock/pgcourse-admin14-config.lock', 'a')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    report('busy', 'Другое применение конфигурации уже выполняется')
    sys.exit(75)

changed = False
before = None
try:
    info = json.loads(run(['docker', 'inspect', 'pgcourse-admin14']))[0]
    assert info['Config']['Labels'].get('pg-course.lesson') == 'admin14'
    assert info['State']['Running']
    assert not current.is_symlink() and not desired.is_symlink()
    before, wanted = current.read_bytes(), desired.read_bytes()
    candidate = state / 'candidate.conf'
    candidate.write_bytes(wanted)
    candidate.chmod(0o644)
    validation_auto = state / 'validation-auto.conf'
    validation_auto.write_bytes(b'')
    validation_auto.chmod(0o644)
    output = run(['docker', 'run', '--rm', '--name', 'pgcourse-admin14-validate', '--pull=never',
        '--network', 'none', '--log-driver', 'none', '--user', '999:999', '--memory', '128m', '--cpus', '0.25',
        '--mount', 'type=bind,src=/opt/pg-course/data/admin14,dst=/var/lib/postgresql,readonly',
        '--mount', f'type=bind,src={validation_auto},dst=/var/lib/postgresql/18/docker/postgresql.auto.conf,readonly',
        '--mount', 'type=bind,src=/opt/pg-course/config/admin14,dst=/etc/course,readonly',
        '--mount', f'type=bind,src={candidate},dst=/etc/course/conf.d/90-managed.conf,readonly',
        '--entrypoint', '/bin/bash', 'pg-course-local:18', '-c',
        'set -eu; for key in log_min_duration_statement shared_buffers work_mem; do '
        'value=$(postgres -D /var/lib/postgresql/18/docker -c config_file=/etc/course/postgresql.conf -C "$key"); '
        'printf "%s\\t%s\\n" "$key" "$value"; done'])
    expected = dict(line.split('\t', 1) for line in output.splitlines())
    assert set(expected) == {'work_mem', 'log_min_duration_statement', 'shared_buffers'}
    assert current.read_bytes() == before, 'Файл изменился во время проверки'
    if wanted != before:
        (state / 'previous.conf').write_bytes(before)
        replace(wanted)
        changed = True
        assert sql('SELECT pg_reload_conf()') == 't'
    status, actual = observe(expected)
    if status == 4 and changed:
        raise RuntimeError('Постусловие не достигнуто: ' + json.dumps(actual))
    if status == 4:
        report('drift', json.dumps(dict(expected=expected, actual=actual), ensure_ascii=False))
    elif status == 3:
        report('restart_required', json.dumps(actual, ensure_ascii=False))
    else:
        report('changed' if changed else 'noop', json.dumps(actual, ensure_ascii=False))
    sys.exit(status)
except Exception as error:
    if changed:
        try:
            replace(before)
            sql('SELECT pg_reload_conf()')
            report('rollback', 'Предыдущий файл восстановлен, перечитывание запрошено')
        except Exception:
            logging.exception('status=rollback_failed')
    report('failed', str(error))
    sys.exit(1)
```

```conf
work_mem = '4MB'
log_min_duration_statement = 'broken'
shared_buffers = '64MB'
```

```bash
(
set +e
python3 /opt/pg-course/generated/lecture14/apply.py
result=$?
printf 'Код применения: %s\n' "$result"
test "$result" -eq 1
)
```

```conf
work_mem = '4MB'
log_min_duration_statement = '1000ms'
shared_buffers = '64MB'
```

```bash
python3 /opt/pg-course/generated/lecture14/apply.py
python3 /opt/pg-course/generated/lecture14/apply.py
```

[документации pg_file_settings](https://postgrespro.ru/docs/postgresql/18/view-pg-file-settings)

```sql
SELECT f.name, f.setting AS file_value, f.applied, f.error,
       current_setting(f.name) AS active_value, f.sourcefile
FROM pg_file_settings f
WHERE f.name IN ('work_mem', 'log_min_duration_statement', 'shared_buffers')
ORDER BY f.seqno;
```

## Расхождение источников, перезапуск и возврат

[русской документации ALTER SYSTEM](https://postgrespro.ru/docs/postgresql/18/sql-altersystem)

```sql
ALTER SYSTEM SET work_mem = '8MB';
SELECT pg_reload_conf();
SELECT name, setting, applied, sourcefile
FROM pg_file_settings
WHERE name = 'work_mem'
ORDER BY seqno;
```

```bash
(
set +e
python3 /opt/pg-course/generated/lecture14/apply.py
result=$?
printf 'Код проверки соответствия: %s\n' "$result"
test "$result" -eq 4
)
```

```sql
ALTER SYSTEM RESET work_mem;
SELECT pg_reload_conf();
```

```conf
work_mem = '4MB'
log_min_duration_statement = '1000ms'
shared_buffers = '96MB'
```

```bash
(
set +e
python3 /opt/pg-course/generated/lecture14/apply.py
result=$?
printf 'Код применения: %s\n' "$result"
test "$result" -eq 3
)
```

```bash
(
set -eu
docker stop --signal SIGINT --timeout 60 pgcourse-admin14
docker start pgcourse-admin14
for attempt in $(seq 1 60); do
  if docker exec -e PGPASSWORD='Admin14-admin-2026!' pgcourse-admin14 \
    psql -XAt -h 127.0.0.1 -U postgres -d course -c 'SELECT 1' 2>/dev/null | grep -qx 1; then
    printf 'Новый процесс готов.\n'
    exit 0
  fi
  sleep 1
done
exit 1
)
```

```sql
SELECT pg_postmaster_start_time() AS process_started,
       current_setting('shared_buffers') AS active_shared_buffers,
       pending_restart
FROM pg_settings
WHERE name = 'shared_buffers';
```

```bash
(
set -eu
cp /opt/pg-course/state/lecture14/baseline.conf \
  /opt/pg-course/generated/lecture14/desired.conf
set +e
python3 /opt/pg-course/generated/lecture14/apply.py
result=$?
set -e
test "$result" -eq 3
docker stop --signal SIGINT --timeout 60 pgcourse-admin14
docker start pgcourse-admin14
for attempt in $(seq 1 60); do
  if docker exec -e PGPASSWORD='Admin14-admin-2026!' pgcourse-admin14 \
    psql -XAt -h 127.0.0.1 -U postgres -d course -c 'SELECT 1' 2>/dev/null | grep -qx 1; then
    printf 'Исходная версия запущена.\n'
    exit 0
  fi
  sleep 1
done
exit 1
)
```

```sql
SELECT name, current_setting(name) AS active_value, pending_restart
FROM pg_settings
WHERE name IN ('work_mem', 'log_min_duration_statement', 'shared_buffers')
ORDER BY name;
```

## Административная задача как проверяемая операция

[документации сервисов libpq](https://postgrespro.ru/docs/postgresql/18/libpq-pgservice)

[парольного файла libpq](https://postgrespro.ru/docs/postgresql/18/libpq-pgpass)

```bash
python3 - <<'PY'
from pathlib import Path
import os

root = Path('/opt/pg-course/config/admin14')
(root / 'pg_service.conf').write_text('''[admin14]
host=127.0.0.1
port=5432
dbname=course
user=admin14_job
application_name=lecture14-maint
sslmode=verify-full
sslrootcert=/certs/ca.crt
connect_timeout=5
''')
(root / 'pg_service.conf').chmod(0o644)
password = root / 'maintenance.pgpass'
password.write_text('127.0.0.1:5432:course:admin14_job:Admin14-job-2026!\n')
os.chown(password, 999, 999)
password.chmod(0o600)
PY
```

```sql
BEGIN;
SET LOCAL lock_timeout = '500ms';
SET LOCAL statement_timeout = '3s';
SELECT pg_advisory_xact_lock(140014);
ANALYZE admin14.events;
INSERT INTO admin14.job_state AS s(task, row_count, last_success_at, run_count)
SELECT 'analyze-events', count(*), clock_timestamp(), 1 FROM admin14.events
ON CONFLICT (task) DO UPDATE
SET row_count = EXCLUDED.row_count,
    last_success_at = EXCLUDED.last_success_at,
    run_count = s.run_count + 1;
COMMIT;
SELECT task, row_count, run_count, last_success_at
FROM admin14.job_state
WHERE task = 'analyze-events';
```

```ini
[Unit]
Description=Обслуживание учебной таблицы PostgreSQL admin14
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
User=root
UMask=0077
TimeoutStartSec=15s
ExecStart=/usr/bin/docker exec --user postgres \
  --env PGSERVICEFILE=/etc/course/pg_service.conf \
  --env PGPASSFILE=/etc/course/maintenance.pgpass \
  pgcourse-admin14 psql -X -d service=admin14 \
  -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -f /etc/course/maintenance.sql
StandardOutput=append:/opt/pg-course/logs/admin14-maint/service.log
StandardError=inherit
```

[документации systemd.timer](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)

```ini
[Unit]
Description=Периодический запуск обслуживания PostgreSQL admin14

[Timer]
OnCalendar=hourly
RandomizedDelaySec=30s
AccuracySec=1s
Persistent=true
Unit=pgcourse-admin14-maint.service

[Install]
WantedBy=timers.target
```

```bash
(
set -eu
cd /opt/pg-course
systemd-analyze verify generated/lecture14/pgcourse-admin14-maint.service \
  generated/lecture14/pgcourse-admin14-maint.timer
install -m 0644 generated/lecture14/pgcourse-admin14-maint.service \
  /etc/systemd/system/pgcourse-admin14-maint.service
install -m 0644 generated/lecture14/pgcourse-admin14-maint.timer \
  /etc/systemd/system/pgcourse-admin14-maint.timer
systemctl daemon-reload
systemctl start pgcourse-admin14-maint.service
systemctl start pgcourse-admin14-maint.service
systemctl show pgcourse-admin14-maint.service -p Result -p ExecMainStatus -p ActiveState
)
```

```sql
SELECT task, row_count, run_count, last_success_at,
       clock_timestamp() - last_success_at AS success_age
FROM admin14.job_state
WHERE task = 'analyze-events';
```

```bash
systemctl enable --now pgcourse-admin14-maint.timer
systemctl list-timers --all pgcourse-admin14-maint.timer
```

## Production-переход и завершение рабочей области

[документацию `patronictl restart`](https://patroni.readthedocs.io/en/latest/patronictl.html#patronictl-restart)

```bash
python3 - <<'PY'
from pathlib import Path
import fcntl
import json
import shutil
import subprocess

root = Path('/opt/pg-course').resolve(strict=True)
lock_path = Path('/run/lock/pgcourse-admin14-config.lock')
lock = lock_path.open('a')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
for name in ('pgcourse-admin14-maint.service', 'pgcourse-admin14-maint.timer'):
    installed = Path('/etc/systemd/system') / name
    assert not installed.is_symlink()
    assert installed.read_bytes() == (root / 'generated/lecture14' / name).read_bytes()
subprocess.run(['systemctl', 'disable', '--now', 'pgcourse-admin14-maint.timer'], check=True)
subprocess.run(['systemctl', 'stop', 'pgcourse-admin14-maint.service'], check=True)
subprocess.run(['systemctl', 'clean', '--what=state', 'pgcourse-admin14-maint.timer'], check=True)
if subprocess.run(['systemctl', 'is-failed', '--quiet', 'pgcourse-admin14-maint.service']).returncode == 0:
    subprocess.run(['systemctl', 'reset-failed', 'pgcourse-admin14-maint.service'], check=True)
for name in ('pgcourse-admin14-maint.service', 'pgcourse-admin14-maint.timer'):
    (Path('/etc/systemd/system') / name).unlink()
subprocess.run(['systemctl', 'daemon-reload'], check=True)
info = json.loads(subprocess.check_output(['docker', 'inspect', 'pgcourse-admin14']))[0]
assert info['Config']['Labels'].get('pg-course.lesson') == 'admin14'
subprocess.run(['docker', 'stop', '--signal', 'SIGINT', '--timeout', '60', 'pgcourse-admin14'], check=True)
stopped = json.loads(subprocess.check_output(['docker', 'inspect', 'pgcourse-admin14']))[0]['State']
assert stopped['ExitCode'] == 0 and not stopped['OOMKilled'], stopped
subprocess.run(['docker', 'rm', 'pgcourse-admin14'], check=True)
for relative in ('data/admin14', 'config/admin14', 'state/lecture14', 'generated/lecture14'):
    target = root / relative
    assert not target.is_symlink() and target.resolve(strict=True) == root / relative, target
    assert root in target.resolve().parents, target
    shutil.rmtree(target)
lock.close()
lock_path.unlink()
print('Таймер, служба, экземпляр и рабочие файлы удалены; журналы сохранены.')
PY
```

## Заключение
