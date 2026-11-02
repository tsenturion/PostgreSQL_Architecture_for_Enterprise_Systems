# Capacity planning: прогнозирование нагрузки, планирование ресурсов и оценка роста данных

## Введение

## Прогноз бизнес-нагрузки и переход к пиковым транзакциям

```sql
SELECT pg_is_in_recovery() AS in_recovery;
SET application_name = 'lecture07-A';
CREATE TEMP TABLE capacity_history(week_no integer PRIMARY KEY, orders numeric NOT NULL);
INSERT INTO capacity_history VALUES
    (1, 700000), (2, 735000), (3, 770000), (4, 805000);
SELECT week_no, orders,
       orders - lag(orders) OVER (ORDER BY week_no) AS weekly_increment
FROM capacity_history ORDER BY week_no;
```

[русской документации агрегатов PostgreSQL](https://postgrespro.ru/docs/postgresql/18/functions-aggregate)

```sql
WITH trend AS (
    SELECT regr_slope(orders::double precision, week_no::double precision) AS slope,
           regr_intercept(orders::double precision, week_no::double precision) AS intercept
    FROM capacity_history
), last_point AS (
    SELECT week_no, orders FROM capacity_history ORDER BY week_no DESC LIMIT 1
)
SELECT round((intercept + slope * 12)::numeric) AS linear_orders_week_12,
       round(orders * power(1.05::numeric, 12 - week_no)) AS compound_orders_week_12
FROM trend CROSS JOIN last_point;
```

```sql
CREATE TEMP TABLE capacity_plan AS
WITH forecast AS (
    SELECT (regr_intercept(orders::double precision, week_no::double precision)
          + regr_slope(orders::double precision, week_no::double precision) * 12)::numeric
           AS weekly_orders
    FROM capacity_history
)
SELECT weekly_orders, weekly_orders / 7 AS daily_orders,
       weekly_orders / 7 * 24 * 0.60 / (4 * 3600) * 3 AS target_tps
FROM forecast;
SELECT round(weekly_orders) AS weekly_orders,
       round(daily_orders) AS daily_orders,
       round(target_tps, 2) AS target_tps
FROM capacity_plan;
```

## Измерение размера и прогноз роста данных

[русской документации функций хранения](https://postgrespro.ru/docs/postgresql/18/functions-admin#FUNCTIONS-ADMIN-DBSIZE)

```sql
CREATE TABLE lab.capacity_sample (LIKE sales.orders INCLUDING ALL);
CREATE TEMP TABLE capacity_size_points (
    point integer PRIMARY KEY, row_count bigint, total_bytes bigint
);
INSERT INTO lab.capacity_sample
SELECT * FROM sales.orders ORDER BY order_id LIMIT 4000;
INSERT INTO capacity_size_points
SELECT 1, count(*), pg_total_relation_size('lab.capacity_sample')
FROM lab.capacity_sample;
SELECT point, row_count, total_bytes FROM capacity_size_points;
```

```sql
INSERT INTO lab.capacity_sample
SELECT * FROM sales.orders ORDER BY order_id OFFSET 4000 LIMIT 4000;
INSERT INTO capacity_size_points
SELECT 2, count(*), pg_total_relation_size('lab.capacity_sample')
FROM lab.capacity_sample;
SELECT b.row_count, b.total_bytes,
       round((b.total_bytes - a.total_bytes)::numeric
             / (b.row_count - a.row_count), 2) AS incremental_bytes_per_order
FROM capacity_size_points a CROSS JOIN capacity_size_points b
WHERE a.point = 1 AND b.point = 2;
```

```sql
CREATE TEMP TABLE capacity_unit AS
WITH counts AS (
    SELECT (SELECT count(*) FROM sales.orders) AS orders,
           (SELECT count(*) FROM sales.order_items) AS items
), sizes AS (
    SELECT pg_total_relation_size('sales.orders')
         + pg_total_relation_size('sales.order_items') AS total_bytes
)
SELECT orders, items, items::numeric / orders AS items_per_order,
       total_bytes::numeric / orders AS bytes_per_order,
       total_bytes::numeric / orders * 1.25 AS forecast_bytes_per_order
FROM counts CROSS JOIN sizes;
SELECT orders, items, items_per_order,
       round(bytes_per_order, 2) AS bytes_per_order,
       round(forecast_bytes_per_order, 2) AS forecast_bytes_per_order
FROM capacity_unit;
```

```sql
CREATE TEMP TABLE capacity_storage AS
WITH trend AS (
    SELECT regr_intercept(orders::double precision, week_no::double precision) AS intercept,
           regr_slope(orders::double precision, week_no::double precision) AS slope
    FROM capacity_history
)
SELECT sum((intercept + slope * w)::numeric) AS retained_orders,
       sum((intercept + slope * w)::numeric) * u.forecast_bytes_per_order AS live_bytes
FROM trend CROSS JOIN capacity_unit u CROSS JOIN generate_series(1, 12) AS g(w)
GROUP BY u.forecast_bytes_per_order;
SELECT round(retained_orders) AS retained_orders,
       round(live_bytes / power(1024::numeric, 3), 2) AS live_gib
FROM capacity_storage;
```

## CPU и число одновременно занятых исполнителей

[документации cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)

[русской документации pgbench](https://postgrespro.ru/docs/postgresql/18/pgbench)

```bash
cd /opt/pg-course
python3 <<'PY'
from pathlib import Path
import datetime
import json
import shlex
import subprocess
import time

dc = ['docker', 'compose', '-f', '/opt/pg-course/compose.json']
def run(args):
    return subprocess.check_output(args, text=True).strip()

node = next(n for n in ('pg1', 'pg2') if run(dc + [
    'exec', '-T', '-u', 'postgres', n, 'psql', '-X', '-At', '-d', 'course',
    '-c', 'SELECT NOT pg_is_in_recovery();']) == 't')
container = run(dc + ['ps', '-q', node])
pid = run(['docker', 'inspect', '--format', '{{.State.Pid}}', container])
group = next(line.split(':', 2)[2] for line in
             Path('/proc', pid, 'cgroup').read_text().splitlines() if line.startswith('0::'))
stat_path = Path('/sys/fs/cgroup') / group.lstrip('/') / 'cpu.stat'
def cpu_usec():
    return int(dict(line.split() for line in stat_path.read_text().splitlines())['usage_usec'])

workload = '\\set order_id random(1,50000)\nSELECT amount FROM sales.orders WHERE order_id = :order_id;\n'
client = 'printf %s ' + shlex.quote(workload) + ' >/tmp/lecture07-read.sql\n' + '''
export PGHOST=rw PGPORT=5432 PGDATABASE=course PGUSER=course_app
export PGSSLMODE=verify-full PGSSLROOTCERT=/certs/ca.crt PGCONNECT_TIMEOUT=5
export PGPASSWORD="$APP_PASSWORD"
pgbench -n -c 1 -j 1 -t 2000 -f /tmp/lecture07-read.sql
'''
before = cpu_usec()
start = time.monotonic()
try:
    output = run(dc + ['exec', '-T', '-u', 'postgres', 'pool', '/bin/sh', '-ec', client])
    elapsed = time.monotonic() - start
    used = cpu_usec() - before
    print(output)
    if ('number of transactions actually processed: 2000' not in output
            or 'number of failed transactions: 0' not in output):
        raise RuntimeError('Серия должна завершить 2000 транзакций без ошибок')
    result = dict(primary=node, transactions=2000, elapsed_s=round(elapsed, 3),
                  cpu_ms_per_transaction=round(used / 1000 / 2000, 4),
                  average_busy_cores=round(used / 1_000_000 / elapsed, 4))
    log_dir = Path('/opt/pg-course/logs/capacity-measure')
    log_dir.mkdir(mode=0o750, exist_ok=True)
    with (log_dir / 'service.log').open('a') as log:
        log.write(datetime.datetime.now(datetime.timezone.utc).isoformat() + ' '
                  + json.dumps(result) + '\n')
    print(json.dumps(result, indent=2))
finally:
    subprocess.run(dc + ['exec', '-T', '-u', 'postgres', 'pool',
                        'rm', '-f', '/tmp/lecture07-read.sql'], check=True)
PY
```

```sql
WITH mix(share, cpu_ms) AS (VALUES (0.80::numeric, 1.5::numeric), (0.20, 5.0)),
service AS (SELECT sum(share * cpu_ms) AS cpu_ms FROM mix),
scenarios(label, cost_factor) AS (VALUES ('base', 1::numeric), ('heavier', 2::numeric))
SELECT label, round(p.target_tps, 2) AS target_tps,
       round(s.cpu_ms * cost_factor, 2) AS cpu_ms_per_transaction,
       round(p.target_tps * s.cpu_ms * cost_factor / 1000, 3) AS busy_cores,
       ceil(p.target_tps * s.cpu_ms * cost_factor / 1000 / 0.60) AS required_cores
FROM capacity_plan p CROSS JOIN service s CROSS JOIN scenarios;
```

```sql
CREATE TEMP TABLE capacity_concurrency AS
WITH scenarios(label, hold_s) AS (VALUES ('base', 0.040::numeric), ('slower', 0.080::numeric))
SELECT label, target_tps * hold_s AS mean_busy_backends,
       ceil(target_tps * hold_s * 1.25) AS proposed_pool_size
FROM capacity_plan CROSS JOIN scenarios;
SELECT label, round(mean_busy_backends, 2) AS mean_busy_backends,
       proposed_pool_size, proposed_pool_size <= 30 AS fits_application_budget
FROM capacity_concurrency;
```

## RAM и рабочий набор

```sql
CREATE TEMP TABLE capacity_memory AS
SELECT live_bytes * 0.15 / power(1024::numeric, 2) AS logical_hot_mib,
       live_bytes * 0.15 * 1.30 / power(1024::numeric, 2) AS cache_mib
FROM capacity_storage;
SELECT round(logical_hot_mib, 1) AS logical_hot_mib,
       round(cache_mib, 1) AS total_cache_mib,
       round(cache_mib * 0.25, 1) AS shared_buffer_budget_mib,
       round(cache_mib * 0.75, 1) AS os_file_cache_budget_mib
FROM capacity_memory;
```

[русской документации ресурсов PostgreSQL](https://postgrespro.ru/docs/postgresql/18/runtime-config-resource)

```sql
WITH scenarios(work_mem_mib) AS (VALUES (4::numeric), (16::numeric)),
budget AS (
    SELECT work_mem_mib, cache_mib,
           32 * 8 + 256 + 384 AS process_and_maintenance_mib,
           24 * work_mem_mib + 12 * work_mem_mib * 2 AS execution_mib
    FROM capacity_memory CROSS JOIN scenarios
)
SELECT work_mem_mib, round(cache_mib, 1) AS cache_mib,
       process_and_maintenance_mib, execution_mib,
       round((cache_mib + process_and_maintenance_mib + execution_mib)
             / 0.80 / 1024, 2) AS required_ram_gib
FROM budget;
```

## I/O, сеть и полный бюджет размещения

[русской документации pg_stat_io](https://postgrespro.ru/docs/postgresql/18/monitoring-stats#MONITORING-PG-STAT-IO-VIEW)

```sql
SELECT backend_type, object, context, reads, read_bytes, writes, write_bytes,
       fsyncs, stats_reset
FROM pg_stat_io
WHERE object IN ('relation', 'wal')
ORDER BY object, backend_type, context;
```

```sql
SELECT round(target_tps * 4, 1) AS read_iops,
       round(target_tps * 0.20 * 12, 1) AS normal_write_iops,
       round(target_tps * 0.20 * 12 * 2, 1) AS service_write_iops,
       round(target_tps * 4 * 8192 / power(1024::numeric, 2), 2) AS read_mib_s,
       round(target_tps * 0.20 * 12 * 2 * 8192 / power(1024::numeric, 2), 2)
           AS service_write_mib_s
FROM capacity_plan;
```

```sql
CREATE TEMP TABLE capacity_network AS
SELECT target_tps * 0.20 * 16384 AS wal_bytes_s,
       target_tps * 1000 AS client_in_bytes_s,
       target_tps * 8000 AS client_out_bytes_s
FROM capacity_plan;
SELECT round(wal_bytes_s / power(1024::numeric, 2), 3) AS wal_mib_s,
       round(client_in_bytes_s * 8 * 1.10 / 1000000, 2) AS client_in_mbit_s,
       round((client_out_bytes_s + wal_bytes_s) * 8 * 1.10 / 1000000, 2)
           AS client_and_replica_out_mbit_s
FROM capacity_network;
```

```sql
WITH parts AS (
    SELECT live_bytes * 1.20 + wal_bytes_s * 6 * 3600 AS database_used_bytes,
           live_bytes * 2 * 0.60 + wal_bytes_s * 24 * 3600 * 0.70 AS repo_used_bytes
    FROM capacity_storage CROSS JOIN capacity_network
)
SELECT round(database_used_bytes / 0.75 / power(1024::numeric, 3), 2)
           AS database_volume_gib_per_node,
       round(repo_used_bytes / 0.75 / power(1024::numeric, 3), 2) AS repository_volume_gib,
       round((2 * database_used_bytes + repo_used_bytes) / 0.75
             / power(1024::numeric, 3), 2) AS combined_vm_disk_budget_gib
FROM parts;
```

```bash
df -B1 /opt/pg-course
```

```sql
WITH scenarios(growth_gib_day) AS (VALUES (0.8::numeric), (2::numeric))
SELECT growth_gib_day,
       round((120 - 20) / growth_gib_day, 1) AS runway_days,
       45 + 14 AS required_lead_days,
       round(20 + growth_gib_day * (45 + 14), 1) AS start_expansion_at_free_gib,
       120 <= 20 + growth_gib_day * (45 + 14) AS expansion_should_start
FROM scenarios;
```

```sql
DROP TABLE lab.capacity_sample;
DROP TABLE capacity_history, capacity_plan, capacity_size_points, capacity_unit,
           capacity_storage, capacity_concurrency, capacity_memory, capacity_network;
RESET application_name;
```

## Заключение
