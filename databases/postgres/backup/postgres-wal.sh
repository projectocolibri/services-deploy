#!/bin/bash
# ============================================================================
# PostgreSQL WAL streamer (pg_receivewal)
#
# Purpose:       Copies the primary's write-ahead log (WAL) to the backup
#                directory continuously, as it is written.
# Role:          Point-in-time recovery: a base backup restored and the WAL
#                replayed up to a chosen moment (e.g. just before a bad
#                DROP TABLE). Pulls from the primary, so it works from another
#                server through the VPN client.
#                  1. creates a replication slot on the primary (once), so the
#                     primary keeps WAL this stream has not received yet, up to
#                     max_slot_wal_keep_size
#                  2. runs pg_receivewal into gzip-compressed segments; the
#                     segment being written ends in .partial
#                  3. watchdog: restarts the stream when the primary reports the
#                     slot inactive for WATCHDOG_STRIKES minutes (a silently
#                     dropped connection is otherwise never noticed)
#                Called with "health", runs the health check instead.
#                To stop streaming for good, drop the slot on the primary:
#                  SELECT pg_drop_replication_slot('<WAL_SLOT>');
# Prerequisites: - Image with pg_receivewal, pg_isready and psql of the
#                  server's major version
#                - Replication role on the primary, allowed by pg_hba for
#                  replication and normal connections
#                - Backup directory mounted at /backups
#
# Variables:
#   PRIMARY_HOST          (env) primary to stream from. Default: postgres-primary
#   REPLICATION_USER      (env) replication role on the primary
#   REPLICATION_PASSWORD  (env) password of REPLICATION_USER
#   WAL_SLOT              (env) replication slot name on the primary.
#                         Default: backup_wal
#   PGPASSWORD            (env, exported) password read by the client tools
#   wal_dir               (local) destination of the WAL segments
#   run_dir               (local) container-only state
#   pid_file              (local) PID of the running pg_receivewal
#   active                (local) slot state reported by the primary (t/f)
#   strikes               (local) consecutive watchdog checks found inactive
#   pid                   (local) PID of pg_receivewal
#   "$1"                  (args) "health" runs the health check
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
primary="${PRIMARY_HOST:-postgres-primary}"
slot="${WAL_SLOT:-backup_wal}"
watchdog_strikes=3
export PGPASSWORD="${REPLICATION_PASSWORD:-}"

wal_dir=/backups/wal
run_dir=/run/postgres-wal
pid_file="${run_dir}/pg_receivewal.pid"

log() {
    echo "[postgres-wal] $(date '+%F %T') $*"
}

# ----------------------------------------------------------------------------
# Health check mode
# ----------------------------------------------------------------------------
# Healthy while pg_receivewal is running.
if [ "${1:-}" = "health" ]; then
    [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null
    exit $?
fi

mkdir -p "${run_dir}" "${wal_dir}"
rm -f "${pid_file}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# slot_active: prints t or f for the slot on the primary (empty if unknown).
slot_active() {
    psql --host="${primary}" --username="${REPLICATION_USER}" --dbname=postgres --no-password \
        -tAc "SELECT active FROM pg_replication_slots WHERE slot_name = '${slot}'" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Stream loop
# ----------------------------------------------------------------------------
trap 'log "stopping"; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

while true; do
    until pg_isready --host="${primary}" --username="${REPLICATION_USER}" --quiet; do
        log "waiting for primary ${primary}..."
        sleep 10 & wait $!
    done

    pg_receivewal --host="${primary}" --username="${REPLICATION_USER}" --no-password \
        --slot="${slot}" --create-slot --if-not-exists 2>&1 | sed 's/^/[postgres-wal]   /'

    log "streaming WAL from ${primary} (slot ${slot})"
    # --synchronous flushes every write, so received WAL survives a crash of
    # this server; --no-loop hands reconnection to this script.
    pg_receivewal --host="${primary}" --username="${REPLICATION_USER}" --no-password \
        --directory="${wal_dir}" --slot="${slot}" \
        --compress=gzip --synchronous --no-loop &
    pid=$!
    echo "${pid}" > "${pid_file}"

    # --- Watchdog -----------------------------------------------------------
    strikes=0
    while kill -0 "${pid}" 2>/dev/null; do
        sleep 60 & wait $!
        active="$(slot_active)"
        if [ "${active}" = "f" ]; then
            strikes=$(( strikes + 1 ))
            if [ "${strikes}" -ge "${watchdog_strikes}" ]; then
                log "slot ${slot} inactive on the primary for ${strikes} minutes, restarting the stream"
                kill "${pid}" 2>/dev/null
            fi
        else
            strikes=0
        fi
    done

    wait "${pid}" 2>/dev/null
    rm -f "${pid_file}"
    log "stream stopped, reconnecting in 10s"
    sleep 10 & wait $!
done
