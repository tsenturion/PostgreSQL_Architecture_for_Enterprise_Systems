#!/usr/bin/env bash
# Установка учебного стенда в отдельный каталог без изменения сетевых настроек ВМ.
set -Eeuo pipefail
umask 077

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LAB_HOME=${LAB_HOME:-/opt/pg-course}
BIND_ADDRESS=${BIND_ADDRESS:-}
ORDERS=${ORDERS:-}
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Запуск от root: bash install.sh [--check] [--bind-address IP] [--orders ЧИСЛО]
  --check             Только проверить ВМ, ничего не устанавливать.
  --bind-address IP   Адрес публикации портов. По умолчанию 127.0.0.1.
  --orders ЧИСЛО      Начальное число заказов: 1000–100000; по умолчанию 50000.
LAB_HOME задаёт каталог установки; по умолчанию /opt/pg-course.
Повторный запуск сохраняет пароли, данные и уже созданную учебную базу.
EOF
}

while (($#)); do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --bind-address) BIND_ADDRESS=${2:?Требуется IP}; shift 2 ;;
    --orders) ORDERS=${2:?Требуется число}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ $EUID == 0 ]] || { echo 'Запустите установщик от root.' >&2; exit 1; }
[[ -r /etc/os-release ]] || { echo 'Не удалось определить ОС.' >&2; exit 1; }
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || { echo 'Установщик предназначен для Ubuntu Server.' >&2; exit 1; }
case ${VERSION_ID:-} in
  22.04|24.04|26.04|26.10) ;;
  *) echo "Не проверяемая установщиком версия Ubuntu: ${VERSION_ID:-неизвестна}." >&2; exit 1 ;;
esac
[[ $LAB_HOME =~ ^/[a-zA-Z0-9/_-]+$ && $LAB_HOME != / && $LAB_HOME != /opt && $LAB_HOME != /var ]] || {
  echo 'LAB_HOME должен быть абсолютным путём к отдельному каталогу без пробелов.' >&2; exit 1;
}
if [[ -n $ORDERS && ! $ORDERS =~ ^[0-9]+$ ]]; then echo 'ORDERS должен быть числом.' >&2; exit 1; fi
if [[ -n $ORDERS ]] && ((ORDERS < 1000 || ORDERS > 100000)); then echo 'Допустимо 1000–100000 заказов.' >&2; exit 1; fi
if [[ -n $BIND_ADDRESS ]]; then
  [[ $BIND_ADDRESS =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Нужен IPv4-адрес.' >&2; exit 1; }
  ip -4 -o addr show | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$BIND_ADDRESS" || {
    echo "Адрес $BIND_ADDRESS не назначен этой ВМ. Сеть установщик не меняет." >&2; exit 1;
  }
fi
memory_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
((memory_kib >= 2700000 && available_kib >= 1400000)) || {
  echo 'Нужно не менее 3 ГиБ RAM в ВМ и около 1,4 ГиБ доступной памяти перед установкой.' >&2; exit 1;
}
probe=$LAB_HOME
while [[ ! -e $probe ]]; do probe=$(dirname -- "$probe"); done
free_kib=$(df -Pk -- "$probe" | awk 'NR==2 {print $4}')
((free_kib >= 8 * 1024 * 1024)) || { echo 'В файловой системе стенда нужно не менее 8 ГиБ свободного места.' >&2; exit 1; }
if [[ -d $LAB_HOME && ! -f $LAB_HOME/.pg-course-installation && $SOURCE_DIR != "$LAB_HOME" ]] &&
   [[ -n $(find "$LAB_HOME" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  echo "Каталог $LAB_HOME занят и не принадлежит установщику. Укажите другой LAB_HOME." >&2; exit 1
fi
printf 'ОС: %s; RAM: %s МиБ; доступно: %s МиБ; свободный диск: %s МиБ.\n' \
  "$PRETTY_NAME" "$((memory_kib / 1024))" "$((available_kib / 1024))" "$((free_kib / 1024))"
if ! command -v docker >/dev/null; then
  for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
      echo "Обнаружен $package. Автоматически удалять или заменять его установщик не будет." >&2
      echo 'Нужна отдельная чистая Ubuntu-ВМ либо заранее установленный Docker Engine с Compose v2.' >&2
      exit 1
    fi
  done
else
  docker info >/dev/null || { echo 'Docker установлен, но демон недоступен. Проверьте systemctl status docker.' >&2; exit 1; }
  docker compose version >/dev/null || { echo 'Установите Compose v2 для имеющегося Docker; демон не будет переустановлен.' >&2; exit 1; }
fi
((CHECK_ONLY)) && { echo 'Предварительная проверка завершена; установка не выполнялась.'; exit 0; }

install -d -m 0700 "$LAB_HOME" "$LAB_HOME/logs/install" "$LAB_HOME/state"
exec 9>"$LAB_HOME/state/install.lock"
flock -n 9 || { echo 'Другой установщик уже работает.' >&2; exit 1; }
touch "$LAB_HOME/.pg-course-installation"
log_file="$LAB_HOME/logs/install/$(date -u +%Y%m%dT%H%M%S)-$$.log"
exec > >(tee -a "$log_file") 2>&1
trap 'rc=$?; printf "Ошибка установки, строка %s, код %s. Журнал: %s\n" "$LINENO" "$rc" "$log_file" >&2; exit "$rc"' ERR

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl python3 logrotate
if ! command -v docker >/dev/null; then
  install -d -m 0755 /etc/apt/keyrings
  curl --fail --silent --show-error --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/pg-course-docker.asc
  chmod 0644 /etc/apt/keyrings/pg-course-docker.asc
  cat > /etc/apt/sources.list.d/pg-course-docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/pg-course-docker.asc
EOF
  apt-get update
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

configure_args=(--source "$SOURCE_DIR" --home "$LAB_HOME")
[[ -z $BIND_ADDRESS ]] || configure_args+=(--bind-address "$BIND_ADDRESS")
[[ -z $ORDERS ]] || configure_args+=(--orders "$ORDERS")
python3 "$SOURCE_DIR/scripts/configure.py" "${configure_args[@]}"
python3 "$LAB_HOME/scripts/preflight.py" "$LAB_HOME"

cd "$LAB_HOME"
if [[ ! -f certs/ca.crt ]]; then
  openssl req -utf8 -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=Учебный центр PostgreSQL' \
    -keyout certs/ca.key -out certs/ca.crt
fi
if [[ ! -f certs/server.crt ]]; then
  openssl req -new -newkey rsa:2048 -nodes -subj '/CN=master3' \
    -keyout certs/server.key -out certs/server.csr
  openssl x509 -req -in certs/server.csr -CA certs/ca.crt -CAkey certs/ca.key \
    -CAcreateserial -out certs/server.crt -days 825 -extfile certs/server.ext
fi
chmod 0600 certs/ca.key
chmod 0644 certs/ca.crt certs/server.crt
chown 999:999 certs/server.key
chmod 0600 certs/server.key

install -m 0755 bin/labctl /usr/local/bin/labctl
printf '%s\n' "$LAB_HOME" > /etc/pg-course-home
chmod 0600 /etc/pg-course-home
install -m 0644 generated/pg-course-logrotate /etc/pg-course-logrotate
install -m 0644 generated/pg-course-housekeeping.service /etc/systemd/system/pg-course-housekeeping.service
install -m 0644 generated/pg-course-housekeeping.timer /etc/systemd/system/pg-course-housekeeping.timer
systemctl daemon-reload
systemctl enable --now pg-course-housekeeping.timer

docker compose -f compose.json config --quiet
docker compose -f compose.json build pg1
docker compose -f compose.json --profile monitoring pull --policy missing prometheus grafana
docker compose -f compose.json up -d etcd1 etcd2 etcd3
docker compose -f compose.json up -d pg1 pg2
labctl wait-primary
docker compose -f compose.json up -d rw pool
if [[ -f state/reload-proxy ]]; then
  docker compose -f compose.json exec -T rw haproxy -c -f /etc/course/haproxy.cfg
  docker compose -f compose.json restart rw
  rm -f -- state/reload-proxy
fi
labctl seed
labctl wait-replica
labctl backup-init
labctl check
labctl versions
labctl housekeeping
printf '\nСтенд готов. Каталог: %s\nКоманды: labctl status; labctl sql; labctl help\n' "$LAB_HOME"
printf 'Пароли сохранены в %s/.env. Мониторинг: labctl monitoring on\n' "$LAB_HOME"
