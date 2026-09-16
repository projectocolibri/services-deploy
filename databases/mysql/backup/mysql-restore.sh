#!/bin/bash
# ============================================================================
# MySQL restore into a temporary server
#
# Purpose:       Restores the newest full backup, optionally rolled forward to
#                a point in time with the streamed binary logs, into a separate
#                temporary server. Production is never touched.
# Role:          Disaster recovery and restore testing. From the temporary
#                server, dump what you need (a table, a database) or inspect
#                it, then remove it. Run it on the server holding the backups.
#                  1. copies the newest backup into a new Docker volume,
#                     decompresses and prepares it
#                  2. starts the temporary server RESTORE_NAME on it, with
#                     replication disabled
#                  3. replays the binary logs up to TARGET_TIME (UTC); without
#                     TARGET_TIME, up to the last copied event
# Prerequisites: - bash and docker on the host (Linux, or Git Bash on Windows)
#                - Backups in BACKUP_DIR (full/ and binlog/)
#                - MYSQL_ROOT_PASSWORD in the environment, or in
#                  databases/mysql/.env or .env.dev (the backup keeps the
#                  replica's root password)
#
# Usage:
#   databases/mysql/backup/mysql-restore.sh ["YYYY-MM-DD HH:MM:SS"]
#   docker exec -it mysql-restore mysql -uroot -p          # inspect
#   docker exec mysql-restore mysqldump -uroot -p db table > table.sql
#   docker rm -f mysql-restore && docker volume rm mysql-restore   # clean up
#
# Variables:
#   TARGET_TIME          (arg 1) stop replaying before this UTC time.
#                        Default: empty (replay everything)
#   MYSQL_BACKUP_DIR     (env or databases/mysql/.env, .env.dev) MySQL backup
#                        directory; relative to this script's directory
#   BACKUP_DIR           (env or root .env, .env.dev) global backup directory,
#                        used as BACKUP_DIR/mysql when MYSQL_BACKUP_DIR is unset.
#                        Default when both are unset: ./backups/mysql next to
#                        this script (the same rule as compose.yaml)
#   RESTORE_NAME         (env) name of the temporary container and volume.
#                        Default: mysql-restore
#   MYSQL_ROOT_PASSWORD  (env) root password of the backed-up replica. Default:
#                        read from databases/mysql/.env, then .env.dev
#   MSYS_NO_PATHCONV     (env, exported) stops Git Bash from rewriting paths
#   script_dir, stack_dir, root_dir
#                        (local) this script's directory, the MySQL stack, the
#                        repository root
#   backup_dir           (local) resolved MySQL backup directory
#   latest               (local) newest complete backup inside the container
#   password             (local) resolved root password
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
name="${RESTORE_NAME:-mysql-restore}"

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

# Same rule as compose.yaml: MYSQL_BACKUP_DIR, else BACKUP_DIR/mysql, else
# ./backups/mysql; relative paths are relative to this script's directory.
backup_dir="$(setting MYSQL_BACKUP_DIR "${stack_dir}/.env" "${stack_dir}/.env.dev")"
if [ -z "${backup_dir}" ]; then
    backup_dir="$(setting BACKUP_DIR "${root_dir}/.env" "${root_dir}/.env.dev")"
    backup_dir="${backup_dir:-./backups}/mysql"
fi
case "${backup_dir}" in
    /* | [A-Za-z]:*) ;;
    *) backup_dir="${script_dir}/${backup_dir#./}" ;;
esac

password="$(setting MYSQL_ROOT_PASSWORD "${stack_dir}/.env" "${stack_dir}/.env.dev")"

log() {
    echo "[mysql-restore] $*"
}

[ -d "${backup_dir}/full" ] || { log "no backups in ${backup_dir}/full"; exit 1; }
[ -n "${password}" ] || { log "MYSQL_ROOT_PASSWORD not found"; exit 1; }
if docker container inspect "${name}" >/dev/null 2>&1 || docker volume inspect "${name}" >/dev/null 2>&1; then
    log "${name} already exists. Remove it first:"
    log "  docker rm -f ${name}; docker volume rm ${name}"
    exit 1
fi

# ----------------------------------------------------------------------------
# 1. Prepare the newest backup
# ----------------------------------------------------------------------------
docker volume create "${name}" >/dev/null
log "preparing the newest backup into volume ${name}"
docker run --rm --user root \
    -v "${backup_dir}:/backups:ro" -v "${name}:/restore" \
    percona/percona-xtrabackup:8.4 bash -c '
        set -e
        latest=$(find /backups/full -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
            -regex ".*/[0-9]{8}-[0-9]{6}" | sort | tail -1)
        [ -n "${latest}" ] || { echo "no complete backup found"; exit 1; }
        echo "[mysql-restore] backup: ${latest}"
        cp -a "${latest}"/. /restore/
        xtrabackup --decompress --parallel=4 --target-dir=/restore > /tmp/restore.log 2>&1
        find /restore -name "*.zst" -delete
        xtrabackup --defaults-file=/restore/backup-my.cnf --prepare --target-dir=/restore >> /tmp/restore.log 2>&1 \
            || { tail -20 /tmp/restore.log; exit 1; }
        echo "[mysql-restore] GTIDs in the backup: $(cut -f3 /restore/xtrabackup_binlog_info)"
        rm -f /restore/backup.log /restore/.started
        chown -R 1001:1001 /restore'

# ----------------------------------------------------------------------------
# 2. Start the temporary server
# ----------------------------------------------------------------------------
# GTID mode as on the real servers; replication stays off, and the settings
# inherited from the replica are removed so it never connects to the primary.
log "starting temporary server ${name}"
docker run -d --name "${name}" -v "${name}:/var/lib/mysql" -e MYSQL_ROOT_PASSWORD=unused \
    percona/percona-server:8.4 \
    --gtid-mode=ON --enforce-gtid-consistency=ON --skip-replica-start --server-id=99 >/dev/null
until docker exec -e MYSQL_PWD="${password}" "${name}" mysqladmin -uroot ping --silent >/dev/null 2>&1; do
    sleep 2
done
docker exec -e MYSQL_PWD="${password}" "${name}" mysql -uroot -e 'STOP REPLICA; RESET REPLICA ALL;'

# ----------------------------------------------------------------------------
# 3. Replay the binary logs
# ----------------------------------------------------------------------------
# Transactions already in the backup are skipped by their GTIDs. The logs are
# read as root (they are only readable by root).
if compgen -G "${backup_dir}/binlog/*" >/dev/null; then
    log "replaying binary logs${target_time:+ up to ${target_time} UTC}"
    docker run --rm --user root --network "container:${name}" -e TZ=UTC -e MYSQL_PWD="${password}" \
        -e TARGET_TIME="${target_time}" -v "${backup_dir}:/backups:ro" \
        percona/percona-server:8.4 bash -c '
            set -o pipefail
            stop=()
            [ -n "${TARGET_TIME}" ] && stop=(--stop-datetime="${TARGET_TIME}")
            mysqlbinlog "${stop[@]}" $(find /backups/binlog -maxdepth 1 -type f -regex ".*\.[0-9]+" | sort) \
                | mysql -h127.0.0.1 -uroot'
else
    log "no binary logs found, restored to the time of the backup"
fi

log "done. The temporary server ${name} holds the restored data:"
log "  docker exec -it ${name} mysql -uroot -p"
log "  docker exec ${name} mysqldump -uroot -p <database> [table] > dump.sql"
log "remove it when finished:"
log "  docker rm -f ${name}; docker volume rm ${name}"
