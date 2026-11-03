# Platform Engineering для PostgreSQL

## Каталог услуги и заявка команды

[terraform/request.tfvars](18-platform-demo/terraform/request.tfvars)

[terraform/main.tf](18-platform-demo/terraform/main.tf)

[Входные переменные Terraform](https://developer.hashicorp.com/terraform/language/values/variables)

## Terraform и жизненный цикл инфраструктуры

[подготовку инструментов на master3](18-platform-demo/prepare-master3.ps1)

```powershell
& './материалы-преподавателя/18-platform-demo/prepare-master3.ps1'
```

[Установка провайдеров Terraform](https://developer.hashicorp.com/terraform/cli/config/config-file#provider-installation)

```bash
cd /opt/pg-course/generated/platform18
bash platform.sh tf plan -input=false -var='request={service="orders",team="sales",profile="production"}'
```

```bash
cd /opt/pg-course/generated/platform18
bash platform.sh tf plan -input=false -var-file=request.tfvars -out=platform.tfplan
```

[Ресурс контейнера Docker](https://github.com/kreuzwerker/terraform-provider-docker/blob/v4.6.0/docs/resources/container.md)

[Состояние Terraform](https://developer.hashicorp.com/terraform/language/state)

```bash
cd /opt/pg-course/generated/platform18
bash platform.sh tf apply -input=false platform.tfplan
```

## Ansible и конфигурация базы

```bash
cd /opt/pg-course/generated/platform18
bash platform.sh contract
```

[ansible/site.yml](18-platform-demo/ansible/site.yml)

[Модуль управления ролями PostgreSQL](https://docs.ansible.com/projects/ansible/latest/collections/community/postgresql/postgresql_user_module.html)

```bash
cd /opt/pg-course/generated/platform18
bash platform.sh configure && bash platform.sh configure
```

## Выдача среды, проверка и исправление расхождений

```powershell
ssh -4 -N -o ExitOnForwardFailure=yes -L 127.0.0.1:15435:127.0.0.1:15435 master3-root
```

```sql
SELECT current_database() AS database_name,
       current_user AS login,
       current_setting('statement_timeout') AS timeout,
       has_schema_privilege(current_user, 'app', 'USAGE') AS can_use_schema,
       has_schema_privilege(current_user, 'app', 'CREATE') AS can_create_in_schema;
```

```bash
docker exec pg-course-platform18 psql -X -v ON_ERROR_STOP=1 \
  -h /var/run/postgresql -U postgres -d postgres \
  -c "ALTER ROLE svc_orders_app SET statement_timeout = '9s';"
```

```bash
cd /opt/pg-course/generated/platform18
bash platform.sh configure
```

## Заключение
