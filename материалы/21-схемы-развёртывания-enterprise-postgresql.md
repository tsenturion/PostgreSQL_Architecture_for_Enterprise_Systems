# Схемы развёртывания PostgreSQL в корпоративной среде

## Фактическое размещение компонентов

```bash
cd /opt/pg-course
hostname
docker compose -f compose.json ps --format '{{.Service}} {{.State}}'
```

```bash
for dir in /opt/pg-course/data/pg1 /opt/pg-course/data/pg2 /opt/pg-course/backups/repo; do
    printf '%s ' "$dir"
    findmnt -n -T "$dir" -o SOURCE,TARGET,FSTYPE
done
```

[Сравнение решений в документации PostgreSQL](https://postgrespro.ru/docs/postgresql/18/different-replication-solutions)

## Разнесение PostgreSQL, кворума и входов

```sql
WITH layouts(name, database_domains, voter_domains, entry_domains, lost_domain) AS (
    VALUES
        ('master3',
         ARRAY['vm','vm'], ARRAY['vm','vm','vm'], ARRAY['vm'], 'vm'),
        ('три хоста в одной площадке',
         ARRAY['h1','h2'], ARRAY['h1','h2','h3'], ARRAY['h1','h2'], 'h1'),
        ('две зоны, голоса 2+1',
         ARRAY['az-a','az-b'], ARRAY['az-a','az-a','az-b'],
         ARRAY['az-a','az-b'], 'az-a'),
        ('три зоны, голоса 1+1+1',
         ARRAY['az-a','az-b','az-c'], ARRAY['az-a','az-b','az-c'],
         ARRAY['az-a','az-b','az-c'], 'az-a')
), survivors AS (
    SELECT name, lost_domain,
           cardinality(array_remove(database_domains, lost_domain)) AS databases_left,
           cardinality(array_remove(voter_domains, lost_domain)) AS voters_left,
           cardinality(voter_domains) / 2 + 1 AS voters_required,
           cardinality(array_remove(entry_domains, lost_domain)) AS entries_left
    FROM layouts
)
SELECT *,
       databases_left > 0 AND voters_left >= voters_required AND entries_left > 0
           AS placement_prerequisites_met
FROM survivors
ORDER BY name;
```

[документацию Patroni о нескольких ЦОД](https://patroni.readthedocs.io/en/latest/ha_multi_dc.html)

## Варианты исполнения и границы ответственности

[документацию CloudNativePG о размещении](https://cloudnative-pg.io/docs/1.30/scheduling/)

[описание вариантов Amazon RDS Multi-AZ](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.html)

## Размещение резервного контура и путь восстановления

[документации Patroni о нескольких ЦОД](https://patroni.readthedocs.io/en/latest/ha_multi_dc.html)

## Заключение
