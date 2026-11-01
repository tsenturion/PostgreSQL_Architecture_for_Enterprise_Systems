ARG POSTGRES_IMAGE
ARG EXPORTER_IMAGE
FROM ${EXPORTER_IMAGE} AS exporter
FROM ${POSTGRES_IMAGE}

ARG PATRONI_VERSION
ARG PSYCOPG2_VERSION
ARG PGBACKREST_PACKAGE
ARG PGBOUNCER_PACKAGE
ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/opt/patroni/bin:/usr/lib/postgresql/18/bin:$PATH \
    PYTHONUNBUFFERED=1

RUN printf 'create_main_cluster = false\n' > /etc/postgresql-common/createcluster.conf \
    && apt-get update && apt-get install -y --no-install-recommends \
      python3-venv "pgbackrest=${PGBACKREST_PACKAGE}" "pgbouncer=${PGBOUNCER_PACKAGE}" \
      curl ca-certificates openssl tini procps iproute2 \
    && python3 -m venv /opt/patroni \
    && /opt/patroni/bin/pip install --no-cache-dir \
      "patroni[etcd3]==${PATRONI_VERSION}" "psycopg2-binary==${PSYCOPG2_VERSION}" \
    && postgres --version && patroni --version && pgbackrest version && pgbouncer --version \
    && rm -rf /var/lib/apt/lists/*

COPY --from=exporter /bin/postgres_exporter /usr/local/bin/postgres_exporter
COPY entrypoint.sh /usr/local/bin/course-entrypoint
RUN chmod 0755 /usr/local/bin/course-entrypoint && mkdir -p /certs

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/course-entrypoint"]
