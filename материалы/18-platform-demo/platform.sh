#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
dir=$PWD
pg_image=pg-course-local:18
tf_image=hashicorp/terraform:1.16.6
db_log=/opt/pg-course/logs/platform18
ansible_log=/opt/pg-course/logs/platform18-ansible

tf() {
    docker run --rm --pull never \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e TF_CLI_CONFIG_FILE="$dir/.tools/terraform.rc" \
        -v "$dir:$dir" -w "$dir" "$tf_image" -chdir=terraform "$@"
}

python_tools() {
    docker run --rm --pull never --network host \
        -v "$dir:$dir" -w "$dir" \
        -e ANSIBLE_COLLECTIONS_PATH="$dir/.tools/collections" \
        -e ANSIBLE_NOCOLOR=1 \
        --entrypoint /bin/bash "$pg_image" -ec "$@"
}

case "${1:-}" in
    prepare)
        docker image inspect "$pg_image" >/dev/null
        if ! docker image inspect "$tf_image" >/dev/null 2>&1; then
            docker pull "$tf_image"
        fi
        install -d -m 0700 .tools .secrets
        install -d -m 0750 "$db_log" "$ansible_log"
        mirror=.tools/provider-mirror/registry.terraform.io/kreuzwerker/docker
        package=terraform-provider-docker_4.6.0_linux_amd64.zip
        install -d -m 0700 "$mirror"
        if [[ ! -s "$mirror/$package" ]]; then
            temp=$(mktemp "$mirror/.download.XXXXXX")
            trap 'rm -f -- "$temp"' EXIT
            curl -fsSL --retry 3 --max-time 90 \
                "https://github.com/kreuzwerker/terraform-provider-docker/releases/download/v4.6.0/$package" \
                -o "$temp"
            mv -f -- "$temp" "$mirror/$package"
            trap - EXIT
        fi
        cat > .tools/terraform.rc <<EOF
provider_installation {
  filesystem_mirror {
    path    = "$dir/.tools/provider-mirror"
    include = ["registry.terraform.io/kreuzwerker/docker"]
  }
}
EOF
        python3 - <<'PY'
from pathlib import Path
from secrets import token_urlsafe

for name in ('admin', 'app'):
    path = Path('.secrets', name)
    try:
        with path.open('x', encoding='ascii') as stream:
            stream.write(token_urlsafe(24) + '\n')
    except FileExistsError:
        if not path.read_text(encoding='ascii').strip():
            raise SystemExit(f'Пустой файл секрета: {path}')
PY
        python_tools '
            if [[ ! -x .tools/venv/bin/python ]]; then
                /opt/patroni/bin/python3 -m venv .tools/venv
            fi
            .tools/venv/bin/python -m pip install --disable-pip-version-check --no-cache-dir \
                "ansible-core==2.21.6" "psycopg2-binary==2.9.13"
            .tools/venv/bin/ansible-galaxy collection install \
                -r ansible/requirements.yml -p .tools/collections
        '
        tf init -input=false
        ;;
    tf)
        shift
        tf "$@"
        ;;
    contract)
        temp=$(mktemp "$dir/.contract.XXXXXX")
        trap 'rm -f -- "$temp"' EXIT
        tf output -json contract > "$temp"
        mv -f -- "$temp" "$dir/contract.json"
        ;;
    configure)
        flock -n "$dir/.tools/ansible.lock" bash -c '
            docker run --rm --pull never --network host \
                -v "$1:$1:ro" -w "$1" \
                -e ANSIBLE_COLLECTIONS_PATH="$1/.tools/collections" \
                -e ANSIBLE_NOCOLOR=1 -e PYTHONDONTWRITEBYTECODE=1 \
                --entrypoint "$1/.tools/venv/bin/ansible-playbook" pg-course-local:18 \
                -i localhost, ansible/site.yml --extra-vars @contract.json
        ' _ "$dir" 2>&1 | tee -a "$ansible_log/service.log"
        ;;
    *)
        printf 'Использование: bash platform.sh {prepare|tf ...|contract|configure}\n' >&2
        exit 2
        ;;
esac
