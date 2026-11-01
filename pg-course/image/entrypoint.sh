#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

mode=${1:?Не указан режим запуска}
shift

case "$mode" in
  patroni)
    install -d -o postgres -g postgres -m 0700 "$PGDATA"
    install -d -o postgres -g postgres -m 0750 /var/log/course /var/log/course/pgbackrest
    install -d -o postgres -g postgres -m 0770 /var/lib/pgbackrest/repo /var/lib/pgbackrest/lock
    install -d -o postgres -g postgres -m 0775 /var/run/postgresql
    exec >> /var/log/course/service.log 2>&1
    exec gosu postgres patroni /etc/course/patroni.json
    ;;
  pool|exporter)
    install -d -o postgres -g postgres -m 0750 /var/log/course
    exec >> /var/log/course/service.log 2>&1
    case "$mode" in
      pool) exec gosu postgres pgbouncer /etc/course/pgbouncer.ini ;;
      exporter) exec gosu postgres postgres_exporter --web.listen-address=:9187 ;;
    esac
    ;;
  restore)
    install -d -o postgres -g postgres -m 0700 "$PGDATA"
    install -d -o postgres -g postgres -m 0750 /var/log/course
    exec >> /var/log/course/service.log 2>&1
    exec gosu postgres postgres -D "$PGDATA" \
      -c listen_addresses=0.0.0.0 -c port=5432 \
      -c ssl=on -c ssl_cert_file=/certs/server.crt -c ssl_key_file=/certs/server.key \
      -c hba_file=/etc/course/restore_hba.conf \
      -c archive_mode=off -c shared_buffers=64MB -c logging_collector=off
    ;;
  tool)
    exec gosu postgres "$@"
    ;;
  *)
    printf 'Неизвестный режим: %s\n' "$mode" >&2
    exit 2
    ;;
esac
