#!/bin/bash
# First start (empty data dir): clone the master with pg_basebackup and write
# the standby configuration (-R). Afterwards the normal entrypoint just starts
# PostgreSQL, which keeps streaming from the master.
set -e

if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    export PGPASSWORD="${REPLICATION_PASSWORD}"

    until pg_isready --host="${MASTER_HOST}" --username="${REPLICATION_USER}" >/dev/null 2>&1; do
        echo "waiting for master ${MASTER_HOST}..."
        sleep 5
    done

    echo "cloning ${MASTER_HOST} into ${PGDATA}..."
    rm -rf "${PGDATA:?}"/*
    pg_basebackup \
        --host="${MASTER_HOST}" \
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
