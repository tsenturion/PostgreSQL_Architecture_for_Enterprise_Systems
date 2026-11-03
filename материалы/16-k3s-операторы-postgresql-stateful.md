# Контейнеризация PostgreSQL и оркестрация в Kubernetes

## k3s и границы контейнерного окружения

[16-подготовить-k3s.ps1](16-подготовить-k3s.ps1)

```powershell
& './материалы-преподавателя/16-подготовить-k3s.ps1'
```

[Установка k3s](https://docs.k3s.io/quick-start)

[Версии CloudNativePG](https://cloudnative-pg.io/docs/1.30/release_notes/v1.30/)

```bash
k3s kubectl get storageclass local-path -o yaml
```

[Классы хранения Kubernetes](https://kubernetes.io/docs/concepts/storage/storage-classes/)

## StatefulSet и сохранение данных

```bash
bash -euo pipefail <<'BASH'
k3s kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: pg-stateful16
---
apiVersion: v1
kind: Secret
metadata:
  name: pg-manual-auth
  namespace: pg-stateful16
type: Opaque
stringData:
  password: 'Stateful16-demo-9Q!'
---
apiVersion: v1
kind: Service
metadata:
  name: pg-manual
  namespace: pg-stateful16
spec:
  clusterIP: None
  selector:
    app: pg-manual
  ports:
    - port: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pg-manual
  namespace: pg-stateful16
spec:
  serviceName: pg-manual
  replicas: 1
  selector:
    matchLabels:
      app: pg-manual
  template:
    metadata:
      labels:
        app: pg-manual
    spec:
      containers:
        - name: postgres
          image: docker.io/library/pg-course-local:18
          imagePullPolicy: Never
          command: ["/usr/local/bin/docker-entrypoint.sh"]
          args: ["postgres", "-c", "shared_buffers=32MB", "-c", "max_connections=20"]
          env:
            - name: PGDATA
              value: /var/lib/postgresql/18/docker
            - name: POSTGRES_DB
              value: course
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: pg-manual-auth
                  key: password
          ports:
            - containerPort: 5432
          readinessProbe:
            exec:
              command: ["pg_isready", "-h", "127.0.0.1", "-p", "5432", "-U", "postgres", "-d", "course"]
            periodSeconds: 3
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 384Mi
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 1Gi
YAML
k3s kubectl -n pg-stateful16 rollout status statefulset/pg-manual --timeout=180s
BASH
```

[Ресурсы рабочей нагрузки Kubernetes](https://kubernetes.io/ru/docs/concepts/workloads/controllers/)

```powershell
ssh -4 -T -o ExitOnForwardFailure=yes -L 127.0.0.1:15432:127.0.0.1:15432 master3-root 'k3s kubectl -n pg-stateful16 port-forward --address 127.0.0.1 service/pg-manual 15432:5432'
```

```sql
CREATE TABLE IF NOT EXISTS public.state_probe (
    id integer PRIMARY KEY,
    payload text NOT NULL
);
INSERT INTO public.state_probe VALUES (1, 'запись до замены Pod')
ON CONFLICT (id) DO UPDATE SET payload = EXCLUDED.payload
RETURNING id, payload;
```

```bash
bash -euo pipefail <<'BASH'
k=(k3s kubectl -n pg-stateful16)
old_uid=$("${k[@]}" get pod pg-manual-0 -o jsonpath='{.metadata.uid}')
old_pv=$("${k[@]}" get pvc data-pg-manual-0 -o jsonpath='{.spec.volumeName}')
"${k[@]}" delete pod pg-manual-0 --wait=true --timeout=120s
"${k[@]}" wait --for=create pod/pg-manual-0 --timeout=120s
"${k[@]}" wait --for=condition=Ready pod/pg-manual-0 --timeout=180s
new_uid=$("${k[@]}" get pod pg-manual-0 -o jsonpath='{.metadata.uid}')
new_pv=$("${k[@]}" get pvc data-pg-manual-0 -o jsonpath='{.spec.volumeName}')
printf 'Pod: %s -> %s\nPV:  %s -> %s\n' "$old_uid" "$new_uid" "$old_pv" "$new_pv"
test "$old_uid" != "$new_uid"
test -n "$old_pv" && test "$old_pv" = "$new_pv"
BASH
```

```powershell
ssh -4 -T -o ExitOnForwardFailure=yes -L 127.0.0.1:15432:127.0.0.1:15432 master3-root 'k3s kubectl -n pg-stateful16 port-forward --address 127.0.0.1 service/pg-manual 15432:5432'
```

```sql
SELECT id, payload FROM public.state_probe WHERE id = 1;
```

## CloudNativePG и жизненный цикл базы

```bash
bash -euo pipefail <<'BASH'
k3s kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: pg-operator16
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: orders
  namespace: pg-operator16
spec:
  instances: 1
  bootstrap:
    initdb:
      database: orders
      owner: orders_app
  storage:
    storageClass: local-path
    size: 1Gi
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 384Mi
  postgresql:
    parameters:
      shared_buffers: "32MB"
      max_connections: "30"
YAML
k3s kubectl -n pg-operator16 wait --for=condition=Ready cluster/orders --timeout=300s
BASH
```

[Архитектура CloudNativePG](https://cloudnative-pg.io/docs/1.30/architecture/)

```bash
bash -euo pipefail <<'BASH'
k=(k3s kubectl -n pg-operator16)
"${k[@]}" patch cluster orders --type=merge -p '{"spec":{"instances":2}}'
"${k[@]}" wait --for=jsonpath='{.status.readyInstances}'=2 cluster/orders --timeout=300s
"${k[@]}" get cluster orders
"${k[@]}" get pvc
BASH
```

[Репликация в CloudNativePG](https://cloudnative-pg.io/docs/1.30/replication/)

```bash
k3s kubectl -n pg-operator16 get endpointslices \
  -l 'kubernetes.io/service-name in (orders-rw,orders-ro,orders-r)' \
  -o custom-columns='SERVICE:.metadata.labels.kubernetes\.io/service-name,POD:.endpoints[*].targetRef.name,READY:.endpoints[*].conditions.ready'
```

[Управление сервисами CloudNativePG](https://cloudnative-pg.io/docs/1.30/service_management/)

```bash
k3s kubectl delete namespace pg-stateful16 pg-operator16 --timeout=180s
```

## Заключение
