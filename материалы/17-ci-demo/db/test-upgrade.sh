#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
release_id=${1:?Укажите идентификатор релиза}
psql_cmd=(psql -X -w -v ON_ERROR_STOP=1)

# Проверяем переход с предыдущей версии на данных, записанных старым кодом.
bash migrate.sh 1 fixture-v1
"${psql_cmd[@]}" -c "INSERT INTO delivery17.orders (order_id, status) VALUES (101, 'paid');"
bash migrate.sh 2 "$release_id"
bash migrate.sh 2 "${release_id:0:40}-retry"
"${psql_cmd[@]}" -v release_id="$release_id" -f test-upgrade.sql
