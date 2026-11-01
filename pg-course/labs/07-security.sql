-- Проверка назначенных прав без изменения ролей.
SELECT rolname,rolsuper,rolcanlogin FROM pg_roles
WHERE rolname IN ('course_owner','course_app','course_reader','course_migrator','course_monitor');
SELECT role,has_table_privilege(role,'sales.orders','SELECT') AS can_read,
       has_table_privilege(role,'sales.orders','UPDATE') AS can_update
FROM (VALUES('course_app'),('course_reader'),('course_migrator')) AS roles(role);
SELECT ssl,version,cipher FROM pg_stat_ssl WHERE pid=pg_backend_pid();
SELECT rule_number,type,database,user_name,address,auth_method,error FROM pg_hba_file_rules;
