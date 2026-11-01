-- Небольшой пример секционирования с ограниченным числом строк.
CREATE TABLE IF NOT EXISTS lab.events (
  event_id bigint NOT NULL, created_at date NOT NULL, payload text NOT NULL,
  PRIMARY KEY(event_id,created_at)
) PARTITION BY RANGE(created_at);
CREATE TABLE IF NOT EXISTS lab.events_2026_01 PARTITION OF lab.events
FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS lab.events_2026_02 PARTITION OF lab.events
FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
INSERT INTO lab.events
SELECT n,date '2026-01-01'+(n%59)::integer,'Учебное событие'
FROM generate_series(1,10000) AS n ON CONFLICT DO NOTHING;
ANALYZE lab.events;
EXPLAIN (ANALYZE,BUFFERS) SELECT count(*) FROM lab.events
WHERE created_at >= date '2026-02-01' AND created_at < date '2026-03-01';
