-- Запускать через migrate.sh. Одна транзакция на запуск.
BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '20s';
SELECT pg_advisory_xact_lock(1701, 1);

CREATE SCHEMA IF NOT EXISTS delivery17;
CREATE TABLE IF NOT EXISTS delivery17.schema_history (
    version integer PRIMARY KEY CHECK (version IN (1, 2)),
    release_id text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS (
           SELECT 1 FROM delivery17.schema_history WHERE version = 1
       ) AS apply_v1,
       (:target = 2 AND NOT EXISTS (
           SELECT 1 FROM delivery17.schema_history WHERE version = 2
       )) AS apply_v2,
       (:target = 1 AND EXISTS (
           SELECT 1 FROM delivery17.schema_history WHERE version = 2
       )) AS downgrade
\gset

\if :downgrade
DO $$ BEGIN RAISE EXCEPTION 'База уже содержит версию 2'; END $$;
\endif

\if :apply_v1
\ir migrations/V001__orders.sql
INSERT INTO delivery17.schema_history(version, release_id) VALUES (1, :'release_id');
\endif

\if :apply_v2
\ir migrations/V002__delivery_channel.sql
INSERT INTO delivery17.schema_history(version, release_id) VALUES (2, :'release_id');
\endif

COMMIT;

SELECT version, release_id, applied_at
FROM delivery17.schema_history
ORDER BY version;
