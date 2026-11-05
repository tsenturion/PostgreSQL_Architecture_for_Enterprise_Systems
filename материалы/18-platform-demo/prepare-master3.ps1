[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sshOptions = @('-4', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes')
$target = 'master3-root'
$remoteDir = '/opt/pg-course/generated/platform18'
$manifest = @(
    'platform.sh', 'start-postgres.sh', 'terraform/main.tf', 'terraform/request.tfvars',
    'ansible/requirements.yml', 'ansible/site.yml'
)

# При повторной подготовке сохраняем заявку, состояние Terraform и пароли на ВМ.
& ssh @sshOptions $target "umask 077; mkdir -p '$remoteDir/terraform' '$remoteDir/ansible'"
if ($LASTEXITCODE -ne 0) { throw 'Не удалось подготовить каталоги на master3' }
foreach ($relative in $manifest) {
    $localPath = Join-Path $PSScriptRoot $relative
    $destination = "${target}:$remoteDir/$relative"
    if ($relative -eq 'terraform/request.tfvars') {
        & ssh @sshOptions $target "if test -f '$remoteDir/$relative'; then exit 0; fi; exit 3"
        if ($LASTEXITCODE -eq 0) { continue }
        if ($LASTEXITCODE -ne 3) { throw "Проверка заявки на master3 завершилась ошибкой" }
    }
    & scp @sshOptions -q -- $localPath $destination
    if ($LASTEXITCODE -ne 0) { throw "Не удалось скопировать $relative" }
}
& ssh @sshOptions $target "cd '$remoteDir' && bash platform.sh prepare"
if ($LASTEXITCODE -ne 0) { throw 'Подготовка инструментов на master3 завершилась ошибкой' }
