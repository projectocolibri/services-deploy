#!/bin/bash
set -e

if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    export PGPASSWORD="${REPLICATION_PASSWORD}"

    until pg_isready --host="${PRIMARY_HOST}" --username="${REPLICATION_USER}" >/dev/null 2>&1; do
        echo "[replica] waiting for primary ${PRIMARY_HOST}..."
        sleep 5
    done

    echo "[replica] cloning ${PRIMARY_HOST} into ${PGDATA}..."
    rm -rf "${PGDATA:?}"/*
    pg_basebackup \
        --host="${PRIMARY_HOST}" \
        --username="${REPLICATION_USER}" \
        --pgdata="${PGDATA}" \
        --wal-method=stream \
        --checkpoint=fast \
        --write-recovery-conf \
        --progress
    chmod 700 "${PGDATA}"
    unset PGPASSWORD
fi

exec /entrypoint.sh "$@"
