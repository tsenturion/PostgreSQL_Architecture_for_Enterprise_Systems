# Linux-окружение для PostgreSQL: параметры ядра, файловые системы, I/O и NUMA

## Введение

## Уровни окружения и выдача процессорного времени

```bash
uname -r
cd /opt/pg-course
docker compose -f compose.json exec -T pg1 uname -r
```

```bash
(
set -eu
if docker container inspect pgcourse-linux-demo >/dev/null 2>&1; then
  printf 'Контейнер pgcourse-linux-demo уже существует.\n' >&2
  exit 1
fi
install -d -o 999 -g 999 -m 0700 /opt/pg-course/data/linux-demo
install -d -o 999 -g 999 -m 0750 /opt/pg-course/logs/linux-demo
docker run -d --name pgcourse-linux-demo --pull=never --restart=no \
  --label pg-course.lesson=linux --network none --log-driver none \
  --memory 128m --memory-swap 128m --cpus 0.1 --user 999:999 \
  --mount type=bind,src=/opt/pg-course/data/linux-demo,dst=/demo \
  --mount type=bind,src=/opt/pg-course/logs/linux-demo,dst=/var/log/course \
  --entrypoint /bin/sh pg-course-local:18 -c 'exec sleep infinity'
)
```

[документации cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)

```python
from pathlib import Path
import json
import logging
import time

logging.basicConfig(filename='/var/log/course/service.log', level=logging.INFO,
                    format='%(asctime)s lecture10-cpu %(levelname)s %(message)s')
def stats():
    return {key: int(value) for key, value in
            (line.split() for line in Path('/sys/fs/cgroup/cpu.stat').read_text().splitlines())}

try:
    quota = Path('/sys/fs/cgroup/cpu.max').read_text().strip()
    before = stats()
    started = time.monotonic()
    cpu_started = time.process_time()
    while time.process_time() - cpu_started < 0.25:
        sum(range(1000))
    cpu_s = time.process_time() - cpu_started
    elapsed_s = time.monotonic() - started
    after = stats()
    result = dict(cpu_max=quota, cpu_s=round(cpu_s, 4), elapsed_s=round(elapsed_s, 4),
                  throttled_periods=after['nr_throttled'] - before['nr_throttled'],
                  throttled_usec=after['throttled_usec'] - before['throttled_usec'])
    logging.info(json.dumps(result))
    print(json.dumps(result, indent=2))
except Exception:
    logging.exception('Ошибка измерения квоты CPU')
    raise
```

```bash
docker exec -i --user postgres pgcourse-linux-demo /opt/patroni/bin/python3 - \
  < /opt/pg-course/generated/lecture10-cpu.py
```

```bash
docker update --cpus 0.2 pgcourse-linux-demo
docker exec -i --user postgres pgcourse-linux-demo /opt/patroni/bin/python3 - \
  < /opt/pg-course/generated/lecture10-cpu.py
```

## Политики памяти, обратная запись и большие страницы

[документации Linux о vm sysctl](https://docs.kernel.org/admin-guide/sysctl/vm.html)

```bash
sysctl vm.overcommit_memory vm.overcommit_ratio vm.overcommit_kbytes vm.swappiness
```

```bash
sysctl vm.dirty_background_bytes vm.dirty_background_ratio \
       vm.dirty_bytes vm.dirty_ratio \
       vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
```

```conf
vm.dirty_background_bytes = 16777216
vm.dirty_bytes = 67108864
```

```bash
sysctl --dry-run --load /opt/pg-course/generated/lecture10-writeback.conf
```

[русской документации ресурсов PostgreSQL](https://postgrespro.ru/docs/postgresql/18/runtime-config-resource)

```sql
SELECT name, setting, unit, context
FROM pg_settings
WHERE name IN ('shared_memory_type', 'huge_pages', 'huge_pages_status', 'huge_page_size')
ORDER BY name;
```

[документации Transparent Huge Pages](https://docs.kernel.org/admin-guide/mm/transhuge.html)

## Файловая система и завершение записи

[документации файловой системы](https://docs.kernel.org/filesystems/ext4/journal.html)

```bash
findmnt -T /opt/pg-course/data/pg1 -o TARGET,SOURCE,FSTYPE,OPTIONS
cd /opt/pg-course
docker inspect --format '{{range .Mounts}}{{println .Type .Source .Destination}}{{end}}' \
  "$(docker compose -f compose.json ps -q pg1)"
```

[русской документации надёжности WAL](https://postgrespro.ru/docs/postgresql/18/wal-reliability)

```sql
SELECT name, setting FROM pg_settings
WHERE name IN ('fsync', 'full_page_writes', 'wal_sync_method') ORDER BY name;
```

[документации Linux fsync и fdatasync](https://man7.org/linux/man-pages/man2/fsync.2.html)

```bash
docker exec -i --user postgres pgcourse-linux-demo /opt/patroni/bin/python3 - <<'PY'
from pathlib import Path
import json
import logging
import os
import time

logging.basicConfig(filename='/var/log/course/service.log', level=logging.INFO,
                    format='%(asctime)s lecture10-io %(levelname)s %(message)s')
path = Path('/demo/lecture10-sync.bin')
fd = None
created = False
try:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    created = True
    block = b'x' * 65536
    for number in range(1, 4):
        started = time.monotonic()
        remaining = memoryview(block)
        while remaining:
            remaining = remaining[os.write(fd, remaining):]
        written = time.monotonic()
        os.fdatasync(fd)
        synced = time.monotonic()
        result = dict(sample=number, bytes=len(block),
                      write_ms=round((written-started)*1000, 3),
                      sync_ms=round((synced-written)*1000, 3))
        logging.info(json.dumps(result))
        print(json.dumps(result))
except Exception:
    logging.exception('Ошибка измерения записи')
    raise
finally:
    if fd is not None:
        os.close(fd)
    if created:
        path.unlink()
PY
```

## Очереди I/O и параметры PostgreSQL

```bash
lsblk -o NAME,TYPE,ROTA,LOG-SEC,PHY-SEC
```

[документации Linux blk-mq](https://docs.kernel.org/block/blk-mq.html)

[русской документации ресурсов PostgreSQL](https://postgrespro.ru/docs/postgresql/18/runtime-config-resource)

```sql
SELECT name, setting, unit, context, pending_restart
FROM pg_settings
WHERE name IN ('io_method', 'io_workers', 'io_combine_limit',
               'effective_io_concurrency', 'maintenance_io_concurrency')
ORDER BY name;
```

```bash
vmstat -w -y 1 3
```

[документации Pressure Stall Information](https://docs.kernel.org/accounting/psi.html)

## NUMA, привязка CPU и размещение страниц

[документации NUMA Memory Policy](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html)

```bash
lscpu -e=CPU,NODE,SOCKET,CORE,ONLINE
```

```bash
docker update --cpuset-cpus 0 --cpuset-mems 0 pgcourse-linux-demo
docker exec --user postgres pgcourse-linux-demo /opt/patroni/bin/python3 -c '
from pathlib import Path
import json, os
print(json.dumps(dict(affinity=sorted(os.sched_getaffinity(0)),
    cpu_max=Path("/sys/fs/cgroup/cpu.max").read_text().strip(),
    allowed_nodes=Path("/sys/fs/cgroup/cpuset.mems.effective").read_text().strip())))
'
```

```bash
docker exec -i --user postgres pgcourse-linux-demo /opt/patroni/bin/python3 - <<'PY'
from pathlib import Path
import json
import logging
import os
import re

logging.basicConfig(filename='/var/log/course/service.log', level=logging.INFO,
                    format='%(asctime)s lecture10-numa %(levelname)s %(message)s')
data = bytearray(4 * 1024 * 1024)
page_size = os.sysconf('SC_PAGE_SIZE')
for offset in range(0, len(data), page_size):
    data[offset] = 1
pages = {}
for line in Path('/proc/self/numa_maps').read_text().splitlines():
    for node, count in re.findall(r'\bN(\d+)=(\d+)', line):
        pages[node] = pages.get(node, 0) + int(count)
result = dict(allocation_bytes=len(data), process_pages_by_node=pages,
              affinity=sorted(os.sched_getaffinity(0)))
logging.info(json.dumps(result))
print(json.dumps(result, indent=2))
PY
sysctl vm.zone_reclaim_mode
```

```bash
docker stop pgcourse-linux-demo
docker rm pgcourse-linux-demo
rmdir /opt/pg-course/data/linux-demo
rm /opt/pg-course/generated/lecture10-cpu.py \
   /opt/pg-course/generated/lecture10-writeback.conf
```

## Заключение
