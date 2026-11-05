#!/usr/bin/env bash
set -Eeuo pipefail

target=${1:?Укажите целевую версию 1 или 2}
release_id=${2:?Укажите идентификатор релиза}
case "$target" in
    1|2) ;;
    *) printf 'Неизвестная целевая версия: %s\n' "$target" >&2; exit 2 ;;
esac
if [[ ! $release_id =~ ^[a-zA-Z0-9._-]{1,48}$ ]]; then
    printf 'Недопустимый идентификатор релиза\n' >&2
    exit 2
fi

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export PGAPPNAME="migrate17/$release_id"
export PGCONNECT_TIMEOUT=5
started=$SECONDS
status=0
printf 'event=migration_start release=%s target=%s\n' "$release_id" "$target"
psql -X -w -v ON_ERROR_STOP=1 -v target="$target" -v release_id="$release_id" \
    -f "$dir/apply.sql" || status=$?
printf 'event=migration_end release=%s target=%s exit_code=%s duration_seconds=%s\n' \
    "$release_id" "$target" "$status" "$((SECONDS - started))"
exit "$status"
