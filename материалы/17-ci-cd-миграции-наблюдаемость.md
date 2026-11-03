# Интеграция PostgreSQL с GitHub Actions и наблюдаемостью

## Версии схемы и совместимость приложения

[V002__delivery_channel.sql](17-ci-demo/db/migrations/V002__delivery_channel.sql)

[Определение таблицы в версии 1](17-ci-demo/db/migrations/V001__orders.sql)

[ALTER TABLE в PostgreSQL](https://postgrespro.ru/docs/postgresql/18/sql-altertable)

[db/apply.sql](17-ci-demo/db/apply.sql)

## Автоматические проверки в GitHub Actions

[db/test-upgrade.sh](17-ci-demo/db/test-upgrade.sh)

[postgres-migrations.yml](17-ci-demo/.github/workflows/postgres-migrations.yml)

[Сервис PostgreSQL в GitHub Actions](https://docs.github.com/en/actions/tutorials/use-containerized-services/create-postgresql-service-containers)

[Сводка задания GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary)

## Доставка миграции в staging

[postgres-migrations.yml](17-ci-demo/.github/workflows/postgres-migrations.yml)

[Среды GitHub Actions](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)

[Параллельные запуски GitHub Actions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)

```powershell
$demo = Join-Path (Get-Location) 'материалы-преподавателя/17-ci-demo'
ssh -4 -T master3-root 'test ! -e /opt/pg-course/generated/ci17'
if ($LASTEXITCODE -ne 0) { throw 'Учебный каталог уже существует или SSH недоступен' }
scp -4 -r -- $demo master3-root:/opt/pg-course/generated/ci17
if ($LASTEXITCODE -ne 0) { throw 'Не удалось скопировать комплект' }
```

```bash
cd /opt/pg-course/generated/ci17
bash staging.sh start && bash staging.sh migrate 1 baseline17
```

```bash
cd /opt/pg-course/generated/ci17
bash staging.sh migrate 2 release17 && bash staging.sh migrate 2 retry17
```

## Событие релиза в наблюдаемости

```powershell
ssh -4 -N -o ExitOnForwardFailure=yes -L 127.0.0.1:15434:127.0.0.1:15434 master3-root
```

```sql
SELECT version, release_id,
       to_char(applied_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS applied_at_utc
FROM delivery17.schema_history
WHERE version = 2;
```

```bash
cd /opt/pg-course
docker compose -f compose.json --profile monitoring up -d --no-build --pull never exporter1 exporter2 prometheus grafana
curl -fsS --retry 60 --retry-delay 2 --retry-all-errors --max-time 3 http://192.168.0.35:3000/api/health
```

```powershell
ssh -4 -N -o ExitOnForwardFailure=yes -L 127.0.0.1:13000:192.168.0.35:3000 master3-root
```

```powershell
$token = Read-Host 'Токен сервисной учётной записи Grafana' -AsSecureString
$appliedAt = Read-Host 'Время applied_at_utc из DBeaver'
& './материалы-преподавателя/17-ci-demo/publish-annotation.ps1' -Release 'release17' -AppliedAt $appliedAt -Token $token
```

[API аннотаций Grafana](https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/api-legacy/annotations/)

[Отображение аннотаций в Grafana](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/annotate-visualizations/)

[Сервисные учётные записи Grafana](https://grafana.com/docs/grafana/latest/administration/service-accounts/)

```bash
cd /opt/pg-course/generated/ci17
bash staging.sh clean
```

## Заключение
