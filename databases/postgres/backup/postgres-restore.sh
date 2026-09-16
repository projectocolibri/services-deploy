#!/bin/bash
# ============================================================================
# PostgreSQL restore into a temporary server
#
# Purpose:       Restores the newest base backup, optionally recovered to a
#                point in time with the streamed WAL, into a separate temporary
#                server. Production is never touched.
# Role:          Disaster recovery and restore testing. From the temporary
#                server, dump what you need (a table, a database) or inspect
#                it, then remove it. Run it on the server holding the backups.
#                  1. extracts the newest backup into a new Docker volume
#                  2. copies the archived WAL next to it (the streamed files
#                     are readable only by root) and adds the segment still
#                     being written, so the latest changes are recoverable
#                  3. starts the temporary server RESTORE_NAME, which replays
#                     WAL up to TARGET_TIME (UTC), or all of it, and promotes
# Prerequisites: - bash and docker on the host (Linux, or Git Bash on Windows)
#                - Backups in BACKUP_DIR (base/ and wal/)
#
# Usage:
#   databases/postgres/backup/postgres-restore.sh ["YYYY-MM-DD HH:MM:SS"]
#   docker exec -it postgres-restore psql -U postgres              # inspect
#   docker exec postgres-restore pg_dump -U postgres -t table db > table.sql
#   docker rm -f postgres-restore && docker volume rm postgres-restore
#
# Variables:
#   TARGET_TIME       (arg 1) recover up to this UTC time. Default: empty
#                     (recover everything received)
#   POSTGRES_BACKUP_DIR (env or databases/postgres/.env, .env.dev) PostgreSQL
#                     backup directory; relative to this script's directory
#   BACKUP_DIR        (env or root .env, .env.dev) global backup directory,
#                     used as BACKUP_DIR/postgres when POSTGRES_BACKUP_DIR is
#                     unset. Default when both are unset: ./backups/postgres
#                     next to this script (the same rule as compose.yaml)
#   RESTORE_NAME      (env) name of the temporary container and volume.
#                     Default: postgres-restore
#   MSYS_NO_PATHCONV  (env, exported) stops Git Bash from rewriting paths
#   script_dir, stack_dir, root_dir
#                     (local) this script's directory, the PostgreSQL stack,
#                     the repository root
#   backup_dir        (local) resolved PostgreSQL backup directory
#   latest, seg       (local, in container) newest backup, partial segment name
# ============================================================================

set -euo pipefail
export MSYS_NO_PATHCONV=1

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
target_time="${1:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
stack_dir="$(dirname "${script_dir}")"
root_dir="$(cd "${stack_dir}/../.." && pwd)"
name="${RESTORE_NAME:-postgres-restore}"

# setting KEY FILE...: value of KEY from the environment, else from the first
# file that sets it to a non-empty value (empty if none).
setting() {
    local key="$1" value="${!1:-}" f
    shift
    for f in "$@"; do
        [ -n "${value}" ] && break
        [ -f "${f}" ] && value="$(grep -E "^${key}=" "${f}" | tail -1 | cut -d= -f2- || true)"
    done
    echo "${value}"
}

# Same rule as compose.yaml: POSTGRES_BACKUP_DIR, else BACKUP_DIR/postgres,
# else ./backups/postgres; relative paths are relative to this script's
# directory.
backup_dir="$(setting POSTGRES_BACKUP_DIR "${stack_dir}/.env" "${stack_dir}/.env.dev")"
if [ -z "${backup_dir}" ]; then
    backup_dir="$(setting BACKUP_DIR "${root_dir}/.env" "${root_dir}/.env.dev")"
    backup_dir="${backup_dir:-./backups}/postgres"
fi
case "${backup_dir}" in
    /* | [A-Za-z]:*) ;;
    *) backup_dir="${script_dir}/${backup_dir#./}" ;;
esac

log() {
    echo "[postgres-restore] $*"
}

[ -d "${backup_dir}/base" ] || { log "no backups in ${backup_dir}/base"; exit 1; }
if docker container inspect "${name}" >/dev/null 2>&1 || docker volume inspect "${name}" >/dev/null 2>&1; then
    log "${name} already exists. Remove it first:"
    log "  docker rm -f ${name}; docker volume rm ${name}"
    exit 1
fi

# ----------------------------------------------------------------------------
# 1-2. Extract the newest backup and prepare recovery
# ----------------------------------------------------------------------------
# The backup was taken from the standby: standby.signal is replaced by
# recovery.signal (recover, then promote) and primary_conninfo is cleared so
# the temporary server never connects to the primary.
docker volume create "${name}" >/dev/null
log "extracting the newest backup into volume ${name}"
docker run --rm --user root \
    -v "${backup_dir}:/backups:ro" -v "${name}:/data/db" -e TARGET_TIME="${target_time}" \
    percona/percona-distribution-postgresql:17 bash -c '
        set -e
        latest=$(find /backups/base -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
            -regex ".*/[0-9]{8}-[0-9]{6}" | sort | tail -1)
        [ -n "${latest}" ] || { echo "no complete backup found"; exit 1; }
        echo "[postgres-restore] backup: ${latest}"
        lz4 -dc "${latest}/base.tar.lz4" | tar -C /data/db -xf -

        mkdir -p /data/db/restore_wal
        find /backups/wal -maxdepth 1 -name "*.gz" -exec cp {} /data/db/restore_wal/ \;
        for f in /backups/wal/*.gz.partial; do
            [ -e "${f}" ] || continue
            seg=$(basename "${f}" .gz.partial)
            gunzip -c "${f}" > "/data/db/pg_wal/${seg}" 2>/dev/null || true
            truncate -s 16M "/data/db/pg_wal/${seg}"
            echo "[postgres-restore] included the segment being written: ${seg}"
        done

        {
            echo "primary_conninfo = '"''"'"
            echo "restore_command = '"'"'gunzip -c /data/db/restore_wal/%f.gz > %p'"'"'"
            [ -n "${TARGET_TIME}" ] && echo "recovery_target_time = '"'"'${TARGET_TIME}+00'"'"'"
            echo "recovery_target_action = '"'"'promote'"'"'"
        } >> /data/db/postgresql.auto.conf

        rm -f /data/db/standby.signal
        touch /data/db/recovery.signal
        chown -R postgres:postgres /data/db
        chmod 700 /data/db'

# ----------------------------------------------------------------------------
# 3. Start the temporary server and wait for recovery
# ----------------------------------------------------------------------------
log "starting temporary server ${name}, recovering${target_time:+ up to ${target_time} UTC}"
docker run -d --name "${name}" -v "${name}:/data/db" \
    percona/percona-distribution-postgresql:17 \
    postgres -c shared_preload_libraries=pg_stat_monitor -c logging_collector=off >/dev/null
until docker exec "${name}" psql -U postgres -tAc 'SELECT NOT pg_is_in_recovery()' 2>/dev/null | grep -q t; do
    if [ "$(docker inspect -f '{{.State.Running}}' "${name}")" != "true" ]; then
        log "recovery FAILED:"
        docker logs "${name}" 2>&1 | tail -15
        exit 1
    fi
    sleep 2
done
docker logs "${name}" 2>&1 | grep -E 'recovery stopping|archive recovery complete' | sed 's/^/[postgres-restore]   /'

log "done. The temporary server ${name} holds the restored data:"
log "  docker exec -it ${name} psql -U postgres"
log "  docker exec ${name} pg_dump -U postgres [-t table] <database> > dump.sql"
log "remove it when finished:"
log "  docker rm -f ${name}; docker volume rm ${name}"
