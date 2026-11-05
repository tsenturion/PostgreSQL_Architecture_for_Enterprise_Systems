#!/usr/bin/env bash
set -Eeuo pipefail

name=pg-course-staging17
home=/opt/pg-course
dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
password='Staging17-demo-8V!'

case "${1:-}" in
    start)
        if ! docker container inspect "$name" >/dev/null 2>&1; then
            install -d -m 0750 "$home/logs/staging17"
            docker run -d --pull never --name "$name" --label pg-course.lesson=17 \
                --memory 384m --memory-swap 384m --cpus 0.5 --shm-size 128m \
                --log-driver none -p 127.0.0.1:15434:5432 \
                -v "$name:/var/lib/postgresql" \
                -v "$dir:/demo:ro" \
                -v "$home/logs/staging17:/var/log/course" \
                -e PGDATA=/var/lib/postgresql/18/docker \
                -e POSTGRES_DB=delivery -e POSTGRES_PASSWORD="$password" \
                --entrypoint /bin/bash pg-course-local:18 -ec '
                    umask 077
                    install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/18 "$PGDATA"
                    exec /usr/local/bin/docker-entrypoint.sh postgres -c shared_buffers=32MB \
                        >> /var/log/course/service.log 2>&1
                '
        fi
        test "$(docker inspect "$name" --format '{{index .Config.Labels "pg-course.lesson"}}')" = 17
        test "$(docker inspect "$name" --format '{{range .Mounts}}{{if eq .Destination "/demo"}}{{.Source}}{{end}}{{end}}')" = "$dir"
        docker start "$name" >/dev/null
        for ((attempt = 1; attempt <= 60; attempt++)); do
            if docker exec "$name" pg_isready -q -h 127.0.0.1 -U postgres -d delivery; then
                printf 'Учебная база готова на локальном порту ВМ 15434.\n'
                exit 0
            fi
            sleep 1
        done
        printf 'База не ответила. Проверьте %s/logs/staging17/service.log\n' "$home" >&2
        exit 1
        ;;
    migrate)
        test "$(docker inspect "$name" --format '{{index .Config.Labels "pg-course.lesson"}}')" = 17
        target=${2:?Укажите версию}
        release_id=${3:?Укажите идентификатор релиза}
        docker exec "$name" bash -ec '
            export PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=delivery PGUSER=postgres
            export PGPASSWORD="$POSTGRES_PASSWORD"
            exec bash /demo/db/migrate.sh "$@"
        ' _ "$target" "$release_id" 2>&1 | tee -a "$home/logs/staging17/service.log"
        ;;
    clean)
        test "$(docker inspect "$name" --format '{{index .Config.Labels "pg-course.lesson"}}')" = 17
        docker stop --signal SIGINT --timeout 45 "$name"
        docker rm "$name"
        docker volume rm "$name"
        ;;
    *)
        printf 'Использование: bash staging.sh {start|migrate ВЕРСИЯ РЕЛИЗ|clean}\n' >&2
        exit 2
        ;;
esac
