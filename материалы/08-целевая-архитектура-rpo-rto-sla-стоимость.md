# Выбор целевой архитектуры под бизнес-требования: RPO/RTO, SLA, стоимостная эффективность

## Введение

## Бизнес-требования и граница сервиса

```sql
SELECT pg_is_in_recovery() AS in_recovery;
SET application_name = 'lecture08-A';
CREATE TEMP TABLE arch_requirements (
    incident text PRIMARY KEY, rpo_s integer NOT NULL, rto_s integer NOT NULL
);
INSERT INTO arch_requirements VALUES
    ('host_loss', 0, 60),
    ('zone_loss', 0, 90),
    ('region_loss', 300, 1800),
    ('logical_damage', 300, 3600);
CREATE TEMP TABLE arch_contract AS
SELECT 465::numeric AS required_tps, 500::numeric AS max_p95_ms,
       0.9995::numeric AS time_availability_target,
       30 * 24 * 3600 AS window_s;
SELECT * FROM arch_requirements ORDER BY incident;
```

[материале Google SRE о целях сервиса](https://sre.google/workbook/implementing-slos/)

```sql
WITH requests(success, duration_ms) AS (
    VALUES (true, 90), (true, 110), (true, 180),
           (true, 700), (false, 30), (false, 1000)
)
SELECT round(100.0 * count(*) FILTER (WHERE success) / count(*), 2) AS success_percent,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)
           FILTER (WHERE success) AS successful_request_p95_ms
FROM requests;
```

```sql
WITH targets(value) AS (VALUES (0.999::numeric), (0.9995::numeric), (0.9999::numeric))
SELECT value * 100 AS target_percent,
       round(30 * 24 * 3600 * (1 - value), 2) AS allowed_unavailable_seconds,
       round(5000000 * (1 - value)) AS allowed_bad_requests
FROM targets ORDER BY value;
```

## Сценарии отказа и восстановление полезной работы

```sql
CREATE TEMP TABLE arch_recovery_steps(step integer PRIMARY KEY, action text, duration_s integer);
INSERT INTO arch_recovery_steps VALUES
    (1, 'Обнаружение', 10), (2, 'Получение лидерства', 15),
    (3, 'Готовность PostgreSQL', 5), (4, 'Обновление маршрута', 5),
    (5, 'Новое соединение', 10), (6, 'Проверка бизнес-результата', 10);
SELECT step, action, duration_s,
       sum(duration_s) OVER (ORDER BY step) AS completed_at_s
FROM arch_recovery_steps ORDER BY step;
```

[документации Patroni](https://patroni.readthedocs.io/en/latest/replication_modes.html)

```sql
WITH policy AS (
    SELECT 180 AS watermark_age_s, 30 AS check_period_s,
           30 AS stop_confirmation_s, 15 AS time_uncertainty_s
)
SELECT watermark_age_s + check_period_s + stop_confirmation_s + time_uncertainty_s
           AS modeled_loss_bound_s,
       watermark_age_s + check_period_s + stop_confirmation_s + time_uncertainty_s
           <= r.rpo_s AS fits_region_requirement
FROM policy CROSS JOIN arch_requirements r WHERE incident = 'region_loss';
```

[standby cluster Patroni](https://patroni.readthedocs.io/en/latest/standby_cluster.html)

```sql
CREATE TEMP TABLE arch_placements AS
SELECT region AS control_group, region,
       region || z AS zone, kind || '-' || region || z AS member, kind
FROM (VALUES ('a'), ('b')) AS r(region)
CROSS JOIN generate_series(1, 3) AS n(z)
CROSS JOIN (VALUES ('postgres'), ('dcs')) AS k(kind);
WITH failures(incident, lost_region, lost_zone) AS (
    VALUES ('zone_a1', 'a', 'a1'), ('region_a', 'a', NULL::text)
), totals AS (
    SELECT control_group, count(*) FILTER (WHERE kind = 'dcs') AS total_votes
    FROM arch_placements GROUP BY control_group
), survivors AS (
    SELECT f.incident, p.control_group,
           count(*) FILTER (WHERE kind = 'postgres' AND NOT
             (p.region = f.lost_region AND (f.lost_zone IS NULL OR p.zone = f.lost_zone)))
               AS surviving_postgres,
           count(*) FILTER (WHERE kind = 'dcs' AND NOT
             (p.region = f.lost_region AND (f.lost_zone IS NULL OR p.zone = f.lost_zone)))
               AS surviving_votes
    FROM failures f CROSS JOIN arch_placements p
    GROUP BY f.incident, p.control_group
)
SELECT s.*, t.total_votes / 2 + 1 AS required_votes,
       surviving_votes >= t.total_votes / 2 + 1 AS has_control_quorum,
       surviving_postgres >= 2 AS has_two_data_nodes
FROM survivors s JOIN totals t USING (control_group)
ORDER BY incident, control_group;
```

```bash
cd /opt/pg-course
hostname
docker compose -f compose.json ps --format '{{.Name}} {{.State}} {{.Health}}'
docker compose -f compose.json exec -T -u postgres pg1 \
  patronictl -c /etc/course/patroni.json show-config course
```

## Проверка требований к вариантам архитектуры

```sql
CREATE TEMP TABLE arch_candidates (
    candidate text PRIMARY KEY, description text,
    ready_tps numeric, p95_ms numeric, evidence_verified boolean
);
INSERT INTO arch_candidates VALUES
    ('restore_one', 'Один PostgreSQL и независимый репозиторий восстановления', 600, 180, false),
    ('async_pair', 'Два PostgreSQL, асинхронная передача и три голоса DCS', 600, 180, false),
    ('sync_pair', 'Два PostgreSQL со строгим подтверждением и три голоса DCS', 600, 180, false),
    ('sync_three', 'Три PostgreSQL в трёх зонах, строгое подтверждение', 600, 180, false),
    ('sync_dr_full', 'Два региона с тремя полноразмерными PostgreSQL в каждом', 600, 180, false),
    ('sync_dr_reserve', 'Три полноразмерных узла и три уменьшенных в регионе восстановления', 600, 220, false);
SELECT candidate, description, ready_tps, p95_ms FROM arch_candidates ORDER BY candidate;
```

```sql
CREATE TEMP TABLE arch_assessments AS
WITH estimates(candidate, host_rpo, host_rto, zone_rpo, zone_rto, region_rpo, region_rto) AS (
    VALUES
    ('restore_one', 300, 3600, 300, 7200, 300, 14400),
    ('async_pair', 60, 45, 120, 60, 300, 7200),
    ('sync_pair', 0, 1800, 0, 1800, 300, 7200),
    ('sync_three', 0, 45, 0, 60, 300, 7200),
    ('sync_dr_full', 0, 45, 0, 60, 255, 600),
    ('sync_dr_reserve', 0, 45, 0, 60, 255, 780)
)
SELECT candidate, v.incident, v.rpo_s, v.rto_s
FROM estimates CROSS JOIN LATERAL (VALUES
    ('host_loss', host_rpo, host_rto), ('zone_loss', zone_rpo, zone_rto),
    ('region_loss', region_rpo, region_rto), ('logical_damage', 300, 300)
) AS v(incident, rpo_s, rto_s);
SELECT * FROM arch_assessments ORDER BY candidate, incident;
```

```sql
CREATE TEMP TABLE arch_month_plan AS
SELECT candidate, sum(rto_s) + 60 AS planned_unavailable_s
FROM arch_assessments GROUP BY candidate;
SELECT candidate, planned_unavailable_s,
       k.window_s * (1 - k.time_availability_target) - planned_unavailable_s AS spare_s
FROM arch_month_plan CROSS JOIN arch_contract k
ORDER BY planned_unavailable_s;
```

```sql
CREATE TEMP TABLE arch_fit AS
SELECT c.candidate, c.evidence_verified,
       c.ready_tps >= k.required_tps AND c.p95_ms <= k.max_p95_ms
       AND m.planned_unavailable_s <= k.window_s * (1 - k.time_availability_target)
       AND bool_and(coalesce(a.rpo_s <= r.rpo_s AND a.rto_s <= r.rto_s, false))
           AS modeled_fit
FROM arch_candidates c JOIN arch_month_plan m USING (candidate)
CROSS JOIN arch_contract k CROSS JOIN arch_requirements r
LEFT JOIN arch_assessments a ON a.candidate = c.candidate AND a.incident = r.incident
GROUP BY c.candidate, c.evidence_verified, c.ready_tps, c.p95_ms,
         m.planned_unavailable_s, k.required_tps, k.max_p95_ms,
         k.window_s, k.time_availability_target;
SELECT * FROM arch_fit ORDER BY candidate;
```

## SLA на горизонте эксплуатации

[русской документации PostgreSQL](https://postgrespro.ru/docs/postgresql/18/rangetypes)

```sql
CREATE TEMP TABLE arch_outages(start_s numeric, end_s numeric,
    CHECK (start_s >= 0 AND end_s <= 2592000 AND end_s > start_s));
INSERT INTO arch_outages VALUES (500, 560), (540, 600), (800, 1100), (1300, 1400);
CREATE TEMP TABLE arch_availability AS
WITH merged AS (
    SELECT range_agg(numrange(start_s, end_s, '[)')) AS periods FROM arch_outages
), duration AS (
    SELECT sum(upper(part) - lower(part)) AS unavailable_s
    FROM merged CROSS JOIN LATERAL unnest(periods) AS u(part)
)
SELECT unavailable_s FROM duration;
SELECT (SELECT sum(end_s - start_s) FROM arch_outages) AS raw_sum_s,
       unavailable_s AS union_duration_s
FROM arch_availability;
```

```sql
SELECT round(100 * (1 - a.unavailable_s / k.window_s), 5) AS availability_percent,
       k.window_s * (1 - k.time_availability_target) AS allowed_unavailable_s,
       k.window_s * (1 - k.time_availability_target) - a.unavailable_s AS remaining_s,
       floor((k.window_s * (1 - k.time_availability_target) - a.unavailable_s) / 60)
           AS additional_60s_intervals
FROM arch_availability a CROSS JOIN arch_contract k;
```

## Полная стоимость и чувствительность выбора

```sql
CREATE TEMP TABLE arch_cost_basis (
    candidate text PRIMARY KEY, full_pg integer, small_pg integer, dcs integer,
    routers integer, pools integer, repositories integer,
    zone_gib numeric, region_gib numeric, reservation_fee numeric,
    operation_hours numeric, transition_cost numeric
);
INSERT INTO arch_cost_basis VALUES
    ('restore_one', 1, 0, 0, 2, 2, 1, 0, 0, 0, 6, 40000),
    ('async_pair', 2, 0, 3, 2, 2, 1, 1000, 0, 0, 10, 80000),
    ('sync_pair', 2, 0, 3, 2, 2, 1, 1000, 0, 0, 10, 80000),
    ('sync_three', 3, 0, 3, 2, 2, 1, 1200, 0, 0, 12, 120000),
    ('sync_dr_full', 6, 0, 6, 4, 4, 2, 2400, 3000, 0, 20, 240000),
    ('sync_dr_reserve', 3, 3, 6, 4, 4, 2, 2400, 3000, 3000, 28, 300000);
CREATE TEMP TABLE arch_costs AS
SELECT *, full_pg * 8000 + small_pg * 5000 + dcs * 1000
       + routers * 1000 + pools * 1000 + repositories * 4000
       + zone_gib * 2 + region_gib * 3 + reservation_fee AS infrastructure_monthly
FROM arch_cost_basis;
SELECT candidate, infrastructure_monthly FROM arch_costs ORDER BY infrastructure_monthly;
```

```sql
CREATE TEMP TABLE arch_tco AS
SELECT candidate, infrastructure_monthly,
       operation_hours * 2000 AS operations_monthly,
       transition_cost / 24 AS transition_monthly,
       infrastructure_monthly + operation_hours * 2000 + transition_cost / 24 AS monthly_tco
FROM arch_costs;
SELECT t.*, round(monthly_tco / 4650000, 5) AS cost_per_completed_order
FROM arch_tco t JOIN arch_fit f USING (candidate)
WHERE f.modeled_fit ORDER BY monthly_tco;
```

```sql
WITH rates(hour_rate) AS (VALUES (250::numeric), (1000::numeric), (2000::numeric))
SELECT hour_rate, candidate,
       infrastructure_monthly + transition_cost / 24 + operation_hours * hour_rate AS monthly_tco
FROM arch_costs CROSS JOIN rates
WHERE candidate IN ('sync_dr_full', 'sync_dr_reserve')
ORDER BY hour_rate, monthly_tco;
SELECT round((a.infrastructure_monthly + a.transition_cost / 24
            - b.infrastructure_monthly - b.transition_cost / 24)
             / (b.operation_hours - a.operation_hours), 2) AS equal_cost_hour_rate
FROM arch_costs a CROSS JOIN arch_costs b
WHERE a.candidate = 'sync_dr_full' AND b.candidate = 'sync_dr_reserve';
```

## Выбор и приёмка проектного решения

```sql
CREATE TEMP TABLE arch_decision AS
SELECT t.candidate, t.monthly_tco, f.modeled_fit, f.evidence_verified,
       'proposed'::text AS decision_status
FROM arch_tco t JOIN arch_fit f USING (candidate)
WHERE f.modeled_fit
ORDER BY t.monthly_tco, t.candidate LIMIT 1;
SELECT * FROM arch_decision;
```

```sql
SELECT d.candidate, r.incident, r.rpo_s AS max_loss_s, r.rto_s AS max_recovery_s,
       a.rto_s AS design_recovery_budget_s,
       k.required_tps, k.max_p95_ms, 'planned' AS verification_status
FROM arch_decision d CROSS JOIN arch_requirements r CROSS JOIN arch_contract k
JOIN arch_assessments a ON a.candidate = d.candidate AND a.incident = r.incident
ORDER BY r.incident;
```

```sql
CREATE TABLE lab.arch_probe (
    operation_id uuid PRIMARY KEY,
    amount numeric(12,2) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
GRANT SELECT, INSERT ON lab.arch_probe TO course_app;
```

```bash
cd /opt/pg-course
docker compose -f compose.json exec -T -u root pool /opt/patroni/bin/python3 - <<'PY'
import json
import logging
import os
import time
import uuid
import psycopg2

logging.basicConfig(filename='/var/log/course/service.log', level=logging.INFO,
                    format='%(asctime)s lecture08-probe %(levelname)s %(message)s')
connection = None
operation = str(uuid.uuid4())
started = time.monotonic()
try:
    connection = psycopg2.connect(host='127.0.0.1', port=6432, dbname='course',
        user='course_app', password=os.environ['APP_PASSWORD'], connect_timeout=5,
        sslmode='verify-full', sslrootcert='/certs/ca.crt', application_name='lecture08-probe')
    with connection.cursor() as cursor:
        cursor.execute('INSERT INTO lab.arch_probe(operation_id, amount) VALUES (%s, 100)',
                       (operation,))
    connection.commit()
    acknowledged_ms = (time.monotonic() - started) * 1000
    with connection.cursor() as cursor:
        cursor.execute('SELECT amount FROM lab.arch_probe WHERE operation_id = %s', (operation,))
        row = cursor.fetchone()
    if row is None or row[0] != 100:
        raise RuntimeError('Контрольная сумма операции не совпала')
    verified_ms = (time.monotonic() - started) * 1000
    result = dict(operation_id=operation, amount=str(row[0]), confirmed=True,
                  commit_ack_ms=round(acknowledged_ms, 3), verified_ms=round(verified_ms, 3))
    logging.info(json.dumps(result))
    print(json.dumps(result, indent=2))
except Exception:
    logging.exception('Ошибка контрольной операции')
    raise
finally:
    if connection is not None:
        connection.close()
PY
```

```sql
DROP TABLE lab.arch_probe;
DROP TABLE arch_requirements, arch_contract, arch_recovery_steps, arch_placements,
           arch_candidates, arch_assessments, arch_month_plan, arch_fit, arch_outages,
           arch_availability, arch_cost_basis, arch_costs, arch_tco, arch_decision;
RESET application_name;
```

## Заключение
