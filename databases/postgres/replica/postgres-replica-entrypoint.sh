#!/bin/bash
# ============================================================================
# PostgreSQL replica entrypoint wrapper
#
# Purpose:       Turns an empty data directory into a hot standby of
#                PRIMARY_HOST, then starts PostgreSQL through the image's
#                normal entrypoint.
# Role:          First start (empty data directory): waits for the primary,
#                clones it with pg_basebackup and writes the standby
#                configuration (-R: standby.signal and primary_conninfo).
#                Later starts: skips the clone; PostgreSQL resumes streaming
#                from the primary.
# Prerequisites: - Percona Distribution for PostgreSQL image (provides
#                  /entrypoint.sh, pg_isready, pg_basebackup, sets PGDATA)
#                - Replication role and pg_hba rule on the primary
#
# Variables:
#   PGDATA                (env, set by the image) data directory, /data/db
#   PRIMARY_HOST          (env) host to clone and stream from
#   REPLICATION_USER      (env) replication role on the primary
#   REPLICATION_PASSWORD  (env) password of REPLICATION_USER
#   PGPASSWORD            (env, temporary) password read by pg_isready and
#                         pg_basebackup; unset after the clone
#   "$@"                  (args) command from compose.yaml (postgres and -c
#                         settings)
# ============================================================================

# ----------------------------------------------------------------------------
# Shell options
# ----------------------------------------------------------------------------
# Exit on the first failing command, so a failed clone restarts the container.
set -e

# ----------------------------------------------------------------------------
# First start: clone the primary
# ----------------------------------------------------------------------------
# PG_VERSION exists (non-empty) only in an initialized data directory.
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    export PGPASSWORD="${REPLICATION_PASSWORD}"

    # --- Wait for the primary -----------------------------------------------
    until pg_isready --host="${PRIMARY_HOST}" --username="${REPLICATION_USER}" >/dev/null 2>&1; do
        echo "[replica] waiting for primary ${PRIMARY_HOST}..."
        sleep 5
    done

    # --- Base backup --------------------------------------------------------
    # Clear leftovers of a previous failed attempt (:? aborts if PGDATA is
    # empty), then copy the primary:
    #   --wal-method=stream     stream WAL during the backup so it is consistent
    #   --checkpoint=fast       start immediately instead of waiting for a
    #                           scheduled checkpoint
    #   --write-recovery-conf   write standby.signal and primary_conninfo
    #   --progress              report progress in the logs
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
    # PostgreSQL refuses to start if the data directory is group/world readable.
    chmod 700 "${PGDATA}"
    unset PGPASSWORD
fi

# ----------------------------------------------------------------------------
# Start PostgreSQL
# ----------------------------------------------------------------------------
# Hand over to the image entrypoint (becomes PID 1).
exec /entrypoint.sh "$@"
