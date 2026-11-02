# Транзакционность, ACID, уровни изоляции, механизм MVCC и VACUUM

## Введение

## Транзакционность и ACID

[документации DBeaver](https://dbeaver.com/docs/dbeaver/Auto-and-Manual-Commit-Modes/)

```sql
SET application_name = 'lecture02-A';
SET idle_in_transaction_session_timeout = '30min';
CREATE TABLE IF NOT EXISTS lab.tx_accounts (
    account_id integer PRIMARY KEY,
    balance integer NOT NULL CHECK (balance >= 0)
);
INSERT INTO lab.tx_accounts(account_id, balance)
VALUES (1, 1000), (2, 1000)
ON CONFLICT (account_id) DO UPDATE SET balance = EXCLUDED.balance;
SELECT pg_backend_pid() AS session_a_pid, account_id, balance
FROM lab.tx_accounts ORDER BY account_id;
```

[русской документации о транзакциях](https://postgrespro.ru/docs/postgresql/18/tutorial-transactions)

```sql
BEGIN;
UPDATE lab.tx_accounts SET balance = balance - 100 WHERE account_id = 1;
UPDATE lab.tx_accounts SET balance = balance + 100 WHERE account_id = 2;
SELECT account_id, balance FROM lab.tx_accounts ORDER BY account_id;
ROLLBACK;
SELECT account_id, balance FROM lab.tx_accounts ORDER BY account_id;
```

```sql
BEGIN;
UPDATE lab.tx_accounts SET balance = balance - 100 WHERE account_id = 1;
UPDATE lab.tx_accounts SET balance = balance + 100 WHERE account_id = 2;
COMMIT;
SELECT account_id, balance FROM lab.tx_accounts ORDER BY account_id;
```

```sql
SET application_name = 'lecture02-B';
SET idle_in_transaction_session_timeout = '30min';
SELECT pg_backend_pid() AS session_b_pid, account_id, balance
FROM lab.tx_accounts ORDER BY account_id;
```

[документации SAVEPOINT](https://postgrespro.ru/docs/postgresql/18/sql-savepoint)

```sql
BEGIN;
UPDATE lab.tx_accounts SET balance = balance - 100 WHERE account_id = 1;
SAVEPOINT before_invalid_change;
UPDATE lab.tx_accounts SET balance = -1 WHERE account_id = 2;
```

[документации ROLLBACK TO SAVEPOINT](https://postgrespro.ru/docs/postgresql/18/sql-rollback-to)

```sql
ROLLBACK TO SAVEPOINT before_invalid_change;
UPDATE lab.tx_accounts SET balance = balance + 100 WHERE account_id = 2;
RELEASE SAVEPOINT before_invalid_change;
COMMIT;
SELECT account_id, balance FROM lab.tx_accounts ORDER BY account_id;
```

[русской документации PostgreSQL](https://postgrespro.ru/docs/postgresql/18/runtime-config-wal#RUNTIME-CONFIG-WAL-SETTINGS)

```sql
SELECT current_setting('fsync') AS fsync,
       current_setting('synchronous_commit') AS synchronous_commit;
```

## Уровни изоляции

[русской документации PostgreSQL](https://postgrespro.ru/docs/postgresql/18/transaction-iso)

```sql
UPDATE lab.tx_accounts SET balance = 1000;
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT balance,
       (SELECT count(*) FROM lab.tx_accounts WHERE balance > 1000) AS above_thousand
FROM lab.tx_accounts WHERE account_id = 1;
```

```sql
BEGIN;
UPDATE lab.tx_accounts SET balance = balance + 50 WHERE account_id = 1;
COMMIT;
SELECT balance FROM lab.tx_accounts WHERE account_id = 1;
```

```sql
SELECT balance,
       (SELECT count(*) FROM lab.tx_accounts WHERE balance > 1000) AS above_thousand
FROM lab.tx_accounts WHERE account_id = 1;
COMMIT;
```

```sql
UPDATE lab.tx_accounts SET balance = 1000;
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance,
       (SELECT count(*) FROM lab.tx_accounts WHERE balance > 1000) AS above_thousand
FROM lab.tx_accounts WHERE account_id = 1;
```

```sql
BEGIN;
UPDATE lab.tx_accounts SET balance = balance + 50 WHERE account_id = 1;
COMMIT;
SELECT balance FROM lab.tx_accounts WHERE account_id = 1;
```

```sql
SELECT balance,
       (SELECT count(*) FROM lab.tx_accounts WHERE balance > 1000) AS above_thousand
FROM lab.tx_accounts WHERE account_id = 1;
COMMIT;
SELECT balance,
       (SELECT count(*) FROM lab.tx_accounts WHERE balance > 1000) AS above_thousand
FROM lab.tx_accounts WHERE account_id = 1;
```

```sql
CREATE TABLE IF NOT EXISTS lab.tx_duty (
    engineer_id integer PRIMARY KEY,
    on_call boolean NOT NULL
);
INSERT INTO lab.tx_duty(engineer_id, on_call)
VALUES (1, true), (2, true)
ON CONFLICT (engineer_id) DO UPDATE SET on_call = EXCLUDED.on_call;
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) AS on_call_count FROM lab.tx_duty WHERE on_call;
```

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) AS on_call_count FROM lab.tx_duty WHERE on_call;
UPDATE lab.tx_duty SET on_call = false WHERE engineer_id = 2;
COMMIT;
```

```sql
UPDATE lab.tx_duty SET on_call = false WHERE engineer_id = 1;
COMMIT;
SELECT count(*) AS on_call_count FROM lab.tx_duty WHERE on_call;
```

[разделе Serializable](https://postgrespro.ru/docs/postgresql/18/transaction-iso#XACT-SERIALIZABLE)

```sql
UPDATE lab.tx_duty SET on_call = true;
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) AS on_call_count FROM lab.tx_duty WHERE on_call;
```

```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) AS on_call_count FROM lab.tx_duty WHERE on_call;
UPDATE lab.tx_duty SET on_call = false WHERE engineer_id = 2;
COMMIT;
```

```sql
UPDATE lab.tx_duty SET on_call = false WHERE engineer_id = 1;
```

```sql
ROLLBACK;
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) AS on_call_count FROM lab.tx_duty WHERE on_call;
UPDATE lab.tx_duty
SET on_call = false
WHERE engineer_id = 1
  AND (SELECT count(*) FROM lab.tx_duty WHERE on_call) > 1;
COMMIT;
SELECT engineer_id, on_call FROM lab.tx_duty ORDER BY engineer_id;
```

## Механизм MVCC

[русской документации PostgreSQL](https://postgrespro.ru/docs/postgresql/18/ddl-system-columns)

```sql
CREATE TABLE IF NOT EXISTS lab.tx_versions (
    version_id integer PRIMARY KEY,
    payload text NOT NULL
) WITH (autovacuum_enabled = false);
ALTER TABLE lab.tx_versions SET (autovacuum_enabled = false);
TRUNCATE lab.tx_versions;
INSERT INTO lab.tx_versions(version_id, payload)
SELECT n, repeat('A', 120) FROM generate_series(1, 2000) AS n;
SELECT version_id, left(payload, 1) AS marker, xmin, xmax, ctid
FROM lab.tx_versions WHERE version_id = 1;
```

[разделе о MVCC](https://postgrespro.ru/docs/postgresql/18/mvcc-intro)

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT version_id, left(payload, 1) AS marker, xmin, xmax, ctid
FROM lab.tx_versions WHERE version_id = 1;
```

```sql
BEGIN;
UPDATE lab.tx_versions SET payload = repeat('B', 120);
COMMIT;
SELECT version_id, left(payload, 1) AS marker, xmin, xmax, ctid
FROM lab.tx_versions WHERE version_id = 1;
```

```sql
SELECT version_id, left(payload, 1) AS marker, xmin, xmax, ctid
FROM lab.tx_versions WHERE version_id = 1;
```

## VACUUM и автоочистка

[справочнике DBeaver](https://dbeaver.com/docs/dbeaver/Shortcuts/)

[русской документации VACUUM](https://postgrespro.ru/docs/postgresql/18/sql-vacuum)

```sql
VACUUM (VERBOSE, TRUNCATE FALSE) lab.tx_versions;
```

```sql
COMMIT;
SELECT version_id, left(payload, 1) AS marker, xmin, xmax, ctid
FROM lab.tx_versions WHERE version_id = 1;
RESET idle_in_transaction_session_timeout;
RESET application_name;
```

[разделе о регламентной очистке](https://postgrespro.ru/docs/postgresql/18/routine-vacuuming)

```sql
VACUUM (VERBOSE, ANALYZE, TRUNCATE FALSE) lab.tx_versions;
SELECT n_live_tup, n_dead_tup, last_vacuum, last_analyze,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE relid = 'lab.tx_versions'::regclass;
```

[русской документации автоочистки](https://postgrespro.ru/docs/postgresql/18/runtime-config-vacuum)

```sql
ALTER TABLE lab.tx_versions RESET (autovacuum_enabled);
SELECT c.relname, c.reloptions,
       age(c.relfrozenxid) AS xid_age,
       current_setting('autovacuum') AS autovacuum,
       current_setting('autovacuum_freeze_max_age') AS freeze_max_age
FROM pg_class AS c
WHERE c.oid = 'lab.tx_versions'::regclass;
RESET idle_in_transaction_session_timeout;
RESET application_name;
```

## Заключение
