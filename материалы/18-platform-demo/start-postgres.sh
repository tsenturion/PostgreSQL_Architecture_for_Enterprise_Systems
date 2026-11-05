#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/18 "$PGDATA"
exec /usr/local/bin/docker-entrypoint.sh postgres \
    -c shared_buffers=32MB -c max_connections=30 \
    >> /var/log/course/service.log 2>&1
