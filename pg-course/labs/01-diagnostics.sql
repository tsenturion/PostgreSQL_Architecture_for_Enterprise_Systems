-- Запуск: labctl sql -f /labs/01-diagnostics.sql
SELECT version(), pg_is_in_recovery(), pg_size_pretty(pg_database_size(current_database()));
SELECT name,setting,unit,source,pending_restart FROM pg_settings
WHERE name IN ('shared_buffers','work_mem','maintenance_work_mem','max_connections',
               'max_wal_size','max_slot_wal_keep_size','synchronous_commit','archive_mode');
SELECT pid,usename,application_name,state,wait_event_type,wait_event,
       clock_timestamp()-xact_start AS transaction_age,pg_blocking_pids(pid),left(query,160)
FROM pg_stat_activity WHERE datname=current_database() ORDER BY xact_start NULLS LAST;
SELECT relname,n_live_tup,n_dead_tup,last_autovacuum,last_analyze
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC;
SELECT application_name,state,sync_state,sent_lsn,write_lsn,flush_lsn,replay_lsn
FROM pg_stat_replication;
SELECT slot_name,active,restart_lsn,wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn)::bigint) AS retained_wal
FROM pg_replication_slots;
SELECT * FROM pg_stat_archiver;
SELECT calls,total_exec_time,mean_exec_time,rows,left(query,160)
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
