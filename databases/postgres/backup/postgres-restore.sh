#!/bin/bash
# ============================================================================
# PostgreSQL restore into a temporary server (pgBackRest)
#
# Purpose:       Restores a pgBackRest repository, optionally to a point in
#                time, into a separate temporary server. Production is never
#                touched.
# Role:          Disaster recovery and restore testing. From the temporary
#                server, dump what you need (a table, a database) or inspect
#                it, then remove it. Run it on the server holding the backup
#                volume.
#                  1. pgbackrest restore into a new Docker volume: it picks
#                     the newest backup that ends before TARGET_TIME (or the
#                     newest one) and sets restore_command to archive-get
#                  2. starts the temporary server RESTORE_NAME, which replays
#                     the archived WAL up to TARGET_TIME (UTC), or all of it,
#                     and promotes
# Prerequisites: - bash and docker on the host (Linux, or Git Bash on Windows)
#                - The repository on this server: the volume or folder of
#                  postgres-backup-primary or postgres-backup-replica
#                  (POSTGRES_PRIMARY_BACKUP_VOLUME / POSTGRES_REPLICA_BACKUP_VOLUME in
#                  .env), or a copy brought back from another storage
#                  location
#
# Usage:
#   databases/postgres/backup/postgres-restore.sh [primary|replica] ["YYYY-MM-DD HH:MM:SS"]
#   docker exec -it postgres-restore psql -U postgres              # inspect
#   docker exec postgres-restore pg_dump -U postgres -t table db > table.sql
#   docker rm -f postgres-restore && docker volume rm postgres-restore
#   List the backups: docker compose exec postgres-backup-replica pgbackrest info
#
# Variables:
#   SOURCE            (arg) primary or replica: which side's backups. Default:
#                     the only one on this server
#   TARGET_TIME       (arg) recover up to this UTC time. Default: empty
#                     (recover everything archived)
#   REPO_VOLUME       (env) repository volume or folder to restore from,
#                     overrides SOURCE (e.g. a copy restored from another
#                     storage location)
#   RESTORE_NAME      (env) name of the temporary container and volume.
#                     Default: postgres-restore
#   PROJECT_NAME, POSTGRES_USER, POSTGRES_PRIMARY_BACKUP_VOLUME,
#   POSTGRES_REPLICA_BACKUP_VOLUME
#                     (env or root .env) volume name prefix, superuser and
#                     the backup locations. Defaults: services, postgres, the
#                     volumes postgres-primary-backup, postgres-replica-backup
#   MSYS_NO_PATHCONV  (env, exported) stops Git Bash from rewriting paths
#   script_dir, root_dir
#                     (local) this script's directory, the repository root
#   volume, user      (local) resolved repository (volume or folder) and
#                     superuser
# ============================================================================

set -euo pipefail
export MSYS_NO_PATHCONV=1

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
source_side=""
target_time=""
for arg in "$@"; do
    case "${arg}" in
        primary | replica) source_side="${arg}" ;;
        *) target_time="${arg}" ;;
    esac
done
script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "${script_dir}/../../.." && pwd)"
name="${RESTORE_NAME:-postgres-restore}"
image=percona/percona-distribution-postgresql:17

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

log() {
    echo "[postgres-restore] $*"
}

project="$(setting PROJECT_NAME "${root_dir}/.env")"
project="${project:-services}"
user="$(setting POSTGRES_USER "${root_dir}/.env")"
user="${user:-postgres}"

# ----------------------------------------------------------------------------
# Repository (volume or folder)
# ----------------------------------------------------------------------------
# storage SIDE: the backup volume (with the project prefix) or folder of
# SIDE, from POSTGRES_<SIDE>_BACKUP_VOLUME (.env, default: the volume
# postgres-<side>-backup); empty if it does not exist on this server.
storage() {
    local value
    value="$(setting "POSTGRES_${1^^}_BACKUP_VOLUME" "${root_dir}/.env")"
    value="${value:-postgres-$1-backup}"
    if [[ "${value}" == */* || "${value}" == *\\* ]]; then
        [ -d "${value}" ] && echo "${value}"
    else
        docker volume inspect "${project}_${value}" >/dev/null 2>&1 && echo "${project}_${value}"
    fi
    return 0
}

volume="${REPO_VOLUME:-}"
if [ -z "${volume}" ]; then
    if [ -n "${source_side}" ]; then
        volume="$(storage "${source_side}")"
        [ -n "${volume}" ] || { log "no backups of the ${source_side} on this server (POSTGRES_${source_side^^}_BACKUP_VOLUME)"; exit 1; }
    else
        found=()
        for side in primary replica; do
            v="$(storage "${side}")"
            [ -n "${v}" ] && found+=("${v}")
        done
        if [ "${#found[@]}" -ne 1 ]; then
            log "${#found[@]} backup locations on this server; choose one: primary or replica"
            exit 1
        fi
        volume="${found[0]}"
    fi
fi
# A path is a folder, anything else a volume.
if [[ "${volume}" == */* || "${volume}" == *\\* ]]; then
    [ -d "${volume}" ] || { log "folder ${volume} not found"; exit 1; }
else
    docker volume inspect "${volume}" >/dev/null 2>&1 || { log "volume ${volume} not found"; exit 1; }
fi
if docker container inspect "${name}" >/dev/null 2>&1 || docker volume inspect "${name}" >/dev/null 2>&1; then
    log "${name} already exists. Remove it first:"
    log "  docker rm -f ${name}; docker volume rm ${name}"
    exit 1
fi

# ----------------------------------------------------------------------------
# 1. Restore the backup
# ----------------------------------------------------------------------------
# --archive-mode=off: the temporary server never archives. A backup taken
# from the standby restores the same way: recovery.signal (not
# standby.signal) ignores its primary_conninfo.
restore_args=(--pg1-path=/data/db --archive-mode=off)
if [ -n "${target_time}" ]; then
    restore_args+=(--type=time "--target=${target_time}+00" --target-action=promote)
fi
docker volume create "${name}" >/dev/null
log "restoring from ${volume}${target_time:+ to ${target_time} UTC} into volume ${name}"
docker run --rm -v "${volume}:/var/lib/pgbackrest:ro" -v "${name}:/data/db" \
    -e PGBACKREST_STANZA=main -e PGBACKREST_LOG_LEVEL_CONSOLE=info -e PGBACKREST_LOG_LEVEL_FILE=off \
    --entrypoint pgbackrest "${image}" restore "${restore_args[@]}" \
    | grep -E 'repo1: restore backup set|restore command end' | sed 's/^/[postgres-restore]   /'

# ----------------------------------------------------------------------------
# 2. Start the temporary server and wait for recovery
# ----------------------------------------------------------------------------
# The repository is mounted read-only for archive-get (restore_command).
log "starting temporary server ${name}, replaying WAL"
docker run -d --name "${name}" -v "${name}:/data/db" -v "${volume}:/var/lib/pgbackrest:ro" \
    -e PGBACKREST_STANZA=main -e PGBACKREST_LOG_LEVEL_FILE=off \
    "${image}" \
    postgres -c shared_preload_libraries=pg_stat_monitor -c logging_collector=off >/dev/null
until docker exec "${name}" psql -U "${user}" -d postgres -tAc 'SELECT NOT pg_is_in_recovery()' 2>/dev/null | grep -q t; do
    if [ "$(docker inspect -f '{{.State.Running}}' "${name}")" != "true" ]; then
        log "recovery FAILED:"
        docker logs "${name}" 2>&1 | tail -15
        exit 1
    fi
    sleep 2
done
docker logs "${name}" 2>&1 | grep -E 'recovery stopping|archive recovery complete|last completed transaction' \
    | sed 's/^/[postgres-restore]   /'

log "done. The temporary server ${name} holds the restored data:"
log "  docker exec -it ${name} psql -U ${user}"
log "  docker exec ${name} pg_dump -U ${user} [-t table] <database> > dump.sql"
log "remove it when finished:"
log "  docker rm -f ${name}; docker volume rm ${name}"
