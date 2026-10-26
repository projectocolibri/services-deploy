#!/bin/bash
# ============================================================================
# MySQL restore into a temporary server
#
# Purpose:       Restores a backup volume, optionally to a point in time, into
#                a separate temporary server. Production is never touched.
# Role:          Disaster recovery and restore testing. From the temporary
#                server, dump what you need (a table, a database) or inspect
#                it, then remove it. Run it on the server holding the backup
#                volume.
#                  1. prepares into a new Docker volume the newest chain whose
#                     full backup finished before TARGET_TIME, with its
#                     incrementals finished before it (mysql-backup.sh
#                     prepare)
#                  2. starts the temporary server RESTORE_NAME on it, with
#                     replication disabled
#                  3. replays that server's binary logs from the backup's
#                     position up to TARGET_TIME (UTC); without TARGET_TIME,
#                     up to the last copied event
# Prerequisites: - bash and docker on the host (Linux, or Git Bash on Windows)
#                - The backups on this server: the volume or folder of
#                  mysql-backup-primary or mysql-backup-replica
#                  (MYSQL_PRIMARY_BACKUP_VOLUME / MYSQL_REPLICA_BACKUP_VOLUME in .env), or a
#                  copy brought back from another storage location
#                - MYSQL_ROOT_PASSWORD in the environment, or in the root
#                  .env (the backup keeps the server's root password)
#
# Usage:
#   databases/mysql/backup/mysql-restore.sh [primary|replica] ["YYYY-MM-DD HH:MM:SS"]
#   docker exec -it mysql-restore mysql -uroot -p          # inspect
#   docker exec mysql-restore mysqldump -uroot -p db table > table.sql
#   docker rm -f mysql-restore && docker volume rm mysql-restore   # clean up
#
# Variables:
#   SOURCE               (arg) primary or replica: which side's backups.
#                        Default: the only one on this server
#   TARGET_TIME          (arg) stop replaying before this UTC time.
#                        Default: empty (replay everything)
#   BACKUP_VOLUME        (env) backup volume or folder to restore from,
#                        overrides SOURCE (e.g. a copy restored from another
#                        storage location)
#   RESTORE_NAME         (env) name of the temporary container and volume.
#                        Default: mysql-restore
#   PROJECT_NAME, MYSQL_ROOT_PASSWORD, MYSQL_PRIMARY_BACKUP_VOLUME,
#   MYSQL_REPLICA_BACKUP_VOLUME
#                        (env or root .env) volume name prefix, root password
#                        and the backup locations. Defaults: services, the
#                        volumes mysql-primary-backup, mysql-replica-backup
#   MSYS_NO_PATHCONV     (env, exported) stops Git Bash from rewriting paths
#   script_dir, root_dir (local) this script's directory, the repository root
#   volume, password     (local) resolved backups (volume or folder) and root
#                        password
#   uuid, binlog_file    (local) server whose binary logs are replayed, and
#                        the file the backup ends in
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
name="${RESTORE_NAME:-mysql-restore}"

# Git Bash: docker needs the Windows form of the script's path.
script="${script_dir}/mysql-backup.sh"
command -v cygpath >/dev/null 2>&1 && script="$(cygpath -w "${script}")"

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
    echo "[mysql-restore] $*"
}

project="$(setting PROJECT_NAME "${root_dir}/.env")"
project="${project:-services}"
password="$(setting MYSQL_ROOT_PASSWORD "${root_dir}/.env")"
[ -n "${password}" ] || { log "MYSQL_ROOT_PASSWORD not found"; exit 1; }

# ----------------------------------------------------------------------------
# Backups (volume or folder)
# ----------------------------------------------------------------------------
# storage SIDE: the backup volume (with the project prefix) or folder of
# SIDE, from MYSQL_<SIDE>_BACKUP_VOLUME (.env, default: the volume
# mysql-<side>-backup); empty if it does not exist on this server.
storage() {
    local value
    value="$(setting "MYSQL_${1^^}_BACKUP_VOLUME" "${root_dir}/.env")"
    value="${value:-mysql-$1-backup}"
    if [[ "${value}" == */* || "${value}" == *\\* ]]; then
        [ -d "${value}" ] && echo "${value}"
    else
        docker volume inspect "${project}_${value}" >/dev/null 2>&1 && echo "${project}_${value}"
    fi
    return 0
}

volume="${BACKUP_VOLUME:-}"
if [ -z "${volume}" ]; then
    if [ -n "${source_side}" ]; then
        volume="$(storage "${source_side}")"
        [ -n "${volume}" ] || { log "no backups of the ${source_side} on this server (MYSQL_${source_side^^}_BACKUP_VOLUME)"; exit 1; }
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
# 1. Prepare the backups
# ----------------------------------------------------------------------------
docker volume create "${name}" >/dev/null
log "preparing from ${volume}${target_time:+ for ${target_time} UTC} into volume ${name}"
result="$(docker run --rm --user root -v "${volume}:/backups:ro" -v "${name}:/restore" \
    -v "${script}:/usr/local/bin/mysql-backup.sh:ro" --entrypoint /bin/bash \
    percona/percona-xtrabackup:8.4 /usr/local/bin/mysql-backup.sh prepare "${target_time}")" \
    || { echo "${result}"; log "prepare FAILED"; exit 1; }
echo "${result}" | grep -v '^RESTORE '
read -r _ uuid binlog_file <<< "$(echo "${result}" | grep '^RESTORE ')"

# ----------------------------------------------------------------------------
# 2. Start the temporary server
# ----------------------------------------------------------------------------
# GTID mode as on the real servers; replication stays off, and the settings
# a replica's backup carries are removed so it never connects to a source.
log "starting temporary server ${name}"
docker run -d --name "${name}" -v "${name}:/var/lib/mysql" -e MYSQL_ROOT_PASSWORD=unused \
    percona/percona-server:8.4 \
    --gtid-mode=ON --enforce-gtid-consistency=ON --skip-replica-start --server-id=99 \
    --lower-case-table-names=1 >/dev/null
until docker exec -e MYSQL_PWD="${password}" "${name}" mysqladmin -uroot ping --silent >/dev/null 2>&1; do
    if [ "$(docker inspect -f '{{.State.Running}}' "${name}")" != "true" ]; then
        log "the temporary server FAILED to start:"
        docker logs "${name}" 2>&1 | tail -15
        exit 1
    fi
    sleep 2
done
docker exec -e MYSQL_PWD="${password}" "${name}" mysql -uroot -e 'STOP REPLICA; RESET REPLICA ALL;'

# ----------------------------------------------------------------------------
# 3. Replay the binary logs
# ----------------------------------------------------------------------------
# The backed-up server's files from the one the backup ends in; transactions
# already in the backup are skipped by their GTIDs. Read as root (they are
# only readable by root).
log "replaying binary logs of server ${uuid} from ${binlog_file}${target_time:+ up to ${target_time} UTC}"
docker run --rm --user root --network "container:${name}" -e TZ=UTC -e MYSQL_PWD="${password}" \
    -e TARGET_TIME="${target_time}" -e DIR="/backups/binlog/${uuid}" -e FIRST="${binlog_file}" \
    -v "${volume}:/backups:ro" --entrypoint /bin/bash \
    percona/percona-server:8.4 -c '
        set -o pipefail
        files=()
        for f in $(find "${DIR}" -maxdepth 1 -type f -regex ".*\.[0-9]+" -printf "%f\n" | sort); do
            [[ "${f}" < "${FIRST}" ]] || files+=("${DIR}/${f}")
        done
        [ "${#files[@]}" -gt 0 ] || { echo "[mysql-restore] no binary logs to replay"; exit 0; }
        stop=()
        [ -n "${TARGET_TIME}" ] && stop=(--stop-datetime="${TARGET_TIME}")
        mysqlbinlog "${stop[@]}" "${files[@]}" | mysql -h127.0.0.1 -uroot'

log "done. The temporary server ${name} holds the restored data:"
log "  docker exec -it ${name} mysql -uroot -p"
log "  docker exec ${name} mysqldump -uroot -p <database> [table] > dump.sql"
log "remove it when finished:"
log "  docker rm -f ${name}; docker volume rm ${name}"
