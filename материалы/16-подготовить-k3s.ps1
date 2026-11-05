[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Разворачиваем отдельный Kubernetes рядом с существующим стендом Docker.
$remoteScript = @'
set -Eeuo pipefail
version='v1.36.5+k3s1'
if command -v k3s >/dev/null; then
    if ! k3s --version | awk -v want="$version" '$1=="k3s" && $2=="version" && $3==want {found=1} END {exit !found}'; then
        printf 'Обнаружена другая версия k3s. Проверьте существующий кластер.\n' >&2
        exit 1
    fi
    systemctl is-active --quiet k3s
else
    test ! -e /etc/rancher/k3s/config.yaml
    test ! -d /var/lib/rancher/k3s/server
    installer=$(mktemp)
    trap 'rm -f -- "$installer"' EXIT
    curl -fsSL --retry 3 https://get.k3s.io -o "$installer"
    INSTALL_K3S_VERSION="$version" sh "$installer" server \
        --disable traefik --disable servicelb --disable metrics-server \
        --write-kubeconfig-mode 0600
fi
k3s kubectl wait --for=condition=Ready node/master3 --timeout=180s
k3s kubectl -n kube-system rollout status deployment/local-path-provisioner --timeout=180s
k3s kubectl -n kube-system rollout status deployment/coredns --timeout=180s
docker image inspect pg-course-local:18 >/dev/null
if ! k3s ctr images list -q | awk '$0=="docker.io/library/pg-course-local:18" {found=1} END {exit !found}'; then
    docker save pg-course-local:18 | k3s ctr images import -
fi
operator_url='https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.1.yaml'
k3s kubectl apply --server-side -f "$operator_url"
k3s kubectl wait --for=condition=Established crd/clusters.postgresql.cnpg.io --timeout=120s
k3s kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=240s
'@

$encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript.Replace("`r`n", "`n")))
ssh -4 -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 master3-root "printf '%s' '$encodedScript' | base64 -d | bash"
if ($LASTEXITCODE -ne 0) {
    throw "Подготовка k3s завершилась с кодом $LASTEXITCODE. Проверьте сообщение SSH или команды на ВМ."
}
