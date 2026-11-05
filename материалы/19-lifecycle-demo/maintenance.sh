#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
dir=$PWD
test "$dir" = /opt/pg-course/generated/lifecycle19
name=pg-course-lifecycle19
source=pg-course-lifecycle19-source
candidate=pg-course-lifecycle19-candidate
image=pg-course-local:18
logdir=/opt/pg-course/logs/lifecycle19
pgdata=/var/lib/postgresql/18/docker
oldbin=/opt/old/usr/lib/postgresql/18/bin

install -d -m 0750 "$logdir"
exec 9>"$dir/maintenance.lock"
flock -n 9 || { printf 'Другая операция уже выполняется.\n' >&2; exit 75; }

event() {
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$logdir/service.log"
}

owns_container() {
    test "$(docker inspect "$name" --format '{{index .Config.Labels "pg-course.lesson"}}')" = 19
}

owns_volume() {
    test "$(docker volume inspect "$1" --format '{{index .Labels "pg-course.lesson"}}')" = 19
}

running_variant() {
    owns_container
    docker inspect "$name" --format '{{index .Config.Labels "pg-course.variant"}}'
}

admin() {
    owns_container
    docker exec -i "$name" psql -X -v ON_ERROR_STOP=1 -h /var/run/postgresql -U postgres -d postgres "$@"
}

start_node() {
    local variant=$1 volume=$2 bin=/usr/lib/postgresql/18/bin expected=180006
    local -a old_mount=()
    owns_volume "$volume"
    if [[ $variant == old ]]; then
        bin=$oldbin
        expected=180004
        old_mount=(--mount "type=bind,src=$dir/old,dst=/opt/old,readonly")
    fi
    event "event=start_requested variant=$variant volume=$volume"
    docker run -d --pull never --name "$name" \
        --label pg-course.lesson=19 --label "pg-course.variant=$variant" \
        --memory 384m --memory-swap 384m --cpus 0.5 --shm-size 128m \
        --log-driver none -p 127.0.0.1:15436:5432 \
        -v "$volume:/var/lib/postgresql" -v "$logdir:/var/log/course" \
        "${old_mount[@]}" \
        -e PGDATA="$pgdata" -e SERVER_BIN="$bin" \
        -e POSTGRES_PASSWORD='Lifecycle19-local-admin' \
        --entrypoint /bin/bash "$image" -ec '
            umask 077
            install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/18 "$PGDATA"
            export PATH="$SERVER_BIN:$PATH"
            exec /usr/local/bin/docker-entrypoint.sh postgres -c shared_buffers=32MB -c listen_addresses=0.0.0.0 \
                >> /var/log/course/service.log 2>&1
        ' >/dev/null
    for ((attempt = 1; attempt <= 60; attempt++)); do
        if docker exec "$name" sh -ec '
            PGPASSWORD="$POSTGRES_PASSWORD" psql -XwAt -h 127.0.0.1 -U postgres -d postgres \
                -c "SHOW server_version_num"
        ' 2>/dev/null | grep -qx "$expected"; then
            event "event=server_ready variant=$variant version=$expected"
            return
        fi
        sleep 1
    done
    event "event=server_not_ready variant=$variant log=$logdir/service.log"
    return 1
}

stop_node() {
    local result
    owns_container
    if [[ $(docker inspect "$name" --format '{{.State.Running}}') == true ]]; then
        docker stop --signal SIGINT --timeout 45 "$name" >/dev/null
    fi
    result=$(docker inspect "$name" --format '{{.State.ExitCode}}/{{.State.OOMKilled}}')
    if [[ $result != '0/false' && ${1:-} != discard ]]; then
        event "event=server_stop_failed result=$result"
        return 1
    fi
    docker rm "$name" >/dev/null
    event "event=server_stopped result=$result"
}

sample() {
    admin -At -c "
        SELECT system_identifier, count(*), sum(amount)
        FROM pg_control_system() CROSS JOIN lifecycle19.orders
        GROUP BY system_identifier;
    "
}

assert_frozen() {
    test "$(admin -At -c "SELECT rolcanlogin FROM pg_roles WHERE rolname='lifecycle19_app'")" = f
    test "$(admin -At -c "SELECT count(*) FROM pg_stat_activity WHERE usename='lifecycle19_app'")" = 0
}

extract_server() (
    local series=$1 version=$2 destination=$3 work package
    package="postgresql-${series}_${version}-1.pgdg13+1_amd64.deb"
    if [[ -x "$destination/usr/lib/postgresql/$series/bin/postgres" ]]; then
        return
    fi
    work=$(mktemp -d "$dir/.extract.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    curl -fsSL --retry 3 --max-time 60 \
        "https://apt-archive.postgresql.org/pub/repos/apt/pool/main/p/postgresql-$series/$package" \
        -o "$work/server.deb"
    dpkg-deb -x "$work/server.deb" "$work/unpacked"
    mv -T -- "$work/unpacked" "$destination"
)

case "${1:-}" in
    prepare)
        extract_server 18 18.4 old
        extract_server 17 17.10 major17
        docker run --rm --pull never --mount "type=bind,src=$dir/old,dst=/opt/old,readonly" \
            --entrypoint /bin/bash "$image" -ec \
            "$oldbin/postgres --version; postgres --version"
        ;;
    start)
        test -x old/usr/lib/postgresql/18/bin/postgres
        ! docker container inspect "$name" >/dev/null 2>&1
        ! docker volume inspect "$source" >/dev/null 2>&1
        ! docker volume inspect "$candidate" >/dev/null 2>&1
        test ! -e baseline.txt
        test ! -e opened
        docker volume create --label pg-course.lesson=19 "$source" >/dev/null
        start_node old "$source"
        admin <<'SQL'
BEGIN;
CREATE SCHEMA lifecycle19;
CREATE TABLE lifecycle19.orders (id integer PRIMARY KEY, amount integer NOT NULL);
INSERT INTO lifecycle19.orders VALUES (1, 100), (2, 250);
CREATE ROLE lifecycle19_app LOGIN PASSWORD 'Lifecycle19-app-8R!';
GRANT USAGE ON SCHEMA lifecycle19 TO lifecycle19_app;
GRANT SELECT, INSERT ON lifecycle19.orders TO lifecycle19_app;
COMMIT;
SQL
        ;;
    freeze)
        test "$(running_variant)" = old
        test ! -e opened
        admin -c 'ALTER ROLE lifecycle19_app NOLOGIN;'
        admin -c "SELECT pid, pg_terminate_backend(pid, 5000)
                  FROM pg_stat_activity WHERE usename = 'lifecycle19_app';"
        assert_frozen
        sample > baseline.txt
        test -s baseline.txt
        event "event=writers_closed baseline=$(<baseline.txt)"
        ;;
    patch)
        test "$(running_variant)" = old
        test ! -e opened
        test -s baseline.txt
        assert_frozen
        test "$(sample)" = "$(<baseline.txt)"
        ! docker volume inspect "$candidate" >/dev/null 2>&1
        stop_node
        owns_volume "$source"
        docker volume create --label pg-course.lesson=19 "$candidate" >/dev/null
        docker run --rm --pull never -e LC_ALL=C \
            -v "$source:/source:ro" -v "$candidate:/candidate" \
            --entrypoint /bin/bash "$image" -ec '
                pg_controldata /source/18/docker |
                    grep -Eq "^Database cluster state:[[:space:]]+shut down$"
                cp -a /source/. /candidate/
            '
        event 'event=cold_copy_complete'
        start_node new "$candidate"
        ;;
    verify)
        variant=$(running_variant)
        assert_frozen
        test -s baseline.txt
        actual=$(sample)
        test "$actual" = "$(<baseline.txt)"
        admin -c 'SHOW server_version_num;'
        if [[ $variant == new ]]; then
            admin -c 'SHOW output_plugin_libraries;'
        fi
        event "event=acceptance_passed variant=$variant sample=$actual"
        ;;
    rollback)
        if [[ -e opened ]]; then
            event 'event=rollback_refused reason=writers_opened'
            exit 1
        fi
        test -s baseline.txt
        if docker container inspect "$name" >/dev/null 2>&1; then
            test "$(running_variant)" = new
            stop_node discard
        fi
        start_node old "$source"
        event 'event=rollback_complete variant=old'
        ;;
    open)
        variant=$(running_variant)
        test ! -e opened
        test -s baseline.txt
        assert_frozen
        test "$(sample)" = "$(<baseline.txt)"
        # Сначала закрываем возможность возврата, затем разрешаем клиентский вход.
        printf '%s\n' "$variant" > opened
        admin -c 'ALTER ROLE lifecycle19_app LOGIN;'
        event "event=writers_opened variant=$variant"
        ;;
    major-check)
        test -x major17/usr/lib/postgresql/17/bin/postgres
        docker run --rm -i --pull never --network none \
            --memory 512m --memory-swap 512m --cpus 0.5 --shm-size 128m \
            --tmpfs /work:rw,size=192m \
            --mount "type=bind,src=$dir/major17,dst=/opt/major17,readonly" \
            --entrypoint /bin/bash "$image" -ec '
                install -d -o postgres -g postgres -m 0700 /work/pg17 /work/pg18 /work/check
                cd /work/check
                exec gosu postgres /bin/bash -se
            ' <<'CHECK' 2>&1 | tee -a "$logdir/service.log"
old=/opt/major17/usr/lib/postgresql/17/bin
new=/usr/lib/postgresql/18/bin
"$old/postgres" --version
"$new/postgres" --version
"$old/initdb" -D /work/pg17 --locale=C --encoding=UTF8 --data-checksums -A trust >/dev/null
"$new/initdb" -D /work/pg18 --locale=C --encoding=UTF8 --data-checksums -A trust >/dev/null
"$new/pg_upgrade" --check \
    --old-bindir="$old" --new-bindir="$new" \
    --old-datadir=/work/pg17 --new-datadir=/work/pg18 \
    --old-options='-c shared_buffers=32MB' --new-options='-c shared_buffers=32MB'
CHECK
        event 'event=major_check_passed source=17.10 target=18.6'
        ;;
    clean)
        if docker container inspect "$name" >/dev/null 2>&1; then
            stop_node
        fi
        for volume in "$candidate" "$source"; do
            if docker volume inspect "$volume" >/dev/null 2>&1; then
                owns_volume "$volume"
                docker volume rm "$volume"
            fi
        done
        rm -f -- baseline.txt opened
        event 'event=demo_cleaned'
        ;;
    *)
        printf 'Использование: bash maintenance.sh {prepare|start|freeze|patch|verify|rollback|open|major-check|clean}\n' >&2
        exit 2
        ;;
esac
