#!/bin/bash
# ============================================================================
# MySQL binary log streamer
#
# Purpose:       Copies the primary's binary logs to the backup directory
#                continuously, as they are written.
# Role:          Point-in-time recovery: a full backup restored and the binary
#                logs replayed up to a chosen moment (e.g. just before a bad
#                DROP TABLE). Pulls from the primary, so it works from another
#                server through the VPN client.
#                  1. resumes from the newest local binary log, or starts at
#                     the file the replica is currently reading
#                  2. runs mysqlbinlog --stop-never, which writes every new
#                     event into files identical to the primary's
#                  3. watchdog: restarts the stream when it falls behind the
#                     replica for WATCHDOG_STRIKES minutes (a silently dropped
#                     connection is otherwise never noticed)
#                  4. if the primary already purged the file to resume from,
#                     logs a gap warning and restarts at the current file
#                Called with "health", runs the health check instead.
# Prerequisites: - Image with mysql, mysqladmin and mysqlbinlog 8.4
#                - Replication account on the primary (REPLICATION SLAVE)
#                - Local replica reachable with root, to learn the current file
#                - Backup directory mounted at /backups
#
# Variables:
#   PRIMARY_HOST          (env) primary to stream from. Default: mysql-primary
#   REPLICATION_USER      (env) replication account on the primary
#   REPLICATION_PASSWORD  (env) password of REPLICATION_USER
#   BACKUP_SOURCE_HOST    (env) local replica. Default: mysql-replica
#   MYSQL_ROOT_PASSWORD   (env) root password of the replica
#   BINLOG_SERVER_ID      (env) server ID used on the primary; must differ from
#                         every server and replica. Default: 101
#   binlog_dir            (local) destination of the binary logs
#   run_dir               (local) container-only state
#   repl_cnf, root_cnf    (local) option files with the credentials
#   pid_file              (local) PID of the running mysqlbinlog
#   err_file              (local) stderr of the last mysqlbinlog run
#   reset                 (local) "1" ignores local files and restarts at the
#                         replica's current file (after a gap)
#   file, pos             (local) file and position the replica has read
#   local_size            (local) size of the local copy of that file
#   newest                (local) newest local binary log
#   strikes               (local) consecutive watchdog checks found behind
#   pid                   (local) PID of mysqlbinlog
#   "$1"                  (args) "health" runs the health check
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
primary="${PRIMARY_HOST:-mysql-primary}"
replica="${BACKUP_SOURCE_HOST:-mysql-replica}"
server_id="${BINLOG_SERVER_ID:-101}"
watchdog_strikes=5

binlog_dir=/backups/binlog
run_dir=/run/mysql-binlog
repl_cnf="${run_dir}/replication.cnf"
root_cnf="${run_dir}/root.cnf"
pid_file="${run_dir}/mysqlbinlog.pid"
err_file="${run_dir}/mysqlbinlog.err"

log() {
    echo "[mysql-binlog] $(date '+%F %T') $*"
}

# ----------------------------------------------------------------------------
# Health check mode
# ----------------------------------------------------------------------------
# Healthy while mysqlbinlog is running.
if [ "${1:-}" = "health" ]; then
    [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null
    exit $?
fi

# ----------------------------------------------------------------------------
# Credentials
# ----------------------------------------------------------------------------
mkdir -p "${run_dir}" "${binlog_dir}"
rm -f "${pid_file}"
(
    umask 077
    printf '[client]\nuser=%s\npassword="%s"\n' "${REPLICATION_USER}" "${REPLICATION_PASSWORD}" > "${repl_cnf}"
    printf '[client]\nuser=root\npassword="%s"\n' "${MYSQL_ROOT_PASSWORD}" > "${root_cnf}"
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# replica_field NAME: prints a field of the local replica's SHOW REPLICA STATUS.
replica_field() {
    mysql --defaults-extra-file="${root_cnf}" --host="${replica}" -e 'SHOW REPLICA STATUS\G' 2>/dev/null \
        | awk -F': ' -v k="$1" '{ gsub(/^ +/, "", $1) } $1 == k { print $2 }'
}

# newest_local: prints the newest binary log already copied (empty if none).
newest_local() {
    find "${binlog_dir}" -maxdepth 1 -type f -regex '.*\.[0-9]+' -printf '%f\n' | sort | tail -1
}

# start_file: file to start streaming from: the newest local copy (downloaded
# again from its beginning), or the file the replica is reading.
start_file() {
    local file
    file="$(newest_local)"
    if [ "${reset}" = "1" ] || [ -z "${file}" ]; then
        until file="$(replica_field Source_Log_File)" && [ -n "${file}" ]; do
            log "waiting for replica ${replica} to report its source binary log..."
            sleep 10 & wait $!
        done
    fi
    echo "${file}"
}

# behind: succeeds when the local copy is behind what the replica has read.
behind() {
    local file pos newest local_size
    file="$(replica_field Source_Log_File)"
    pos="$(replica_field Read_Source_Log_Pos)"
    [ -n "${file}" ] && [ -n "${pos}" ] || return 1
    newest="$(newest_local)"
    [[ "${newest}" > "${file}" ]] && return 1
    [ -f "${binlog_dir}/${file}" ] || return 0
    local_size=$(stat -c %s "${binlog_dir}/${file}")
    [ "${local_size}" -lt "${pos}" ]
}

# ----------------------------------------------------------------------------
# Stream loop
# ----------------------------------------------------------------------------
trap 'log "stopping"; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

reset=0
while true; do
    until mysqladmin --defaults-extra-file="${repl_cnf}" --host="${primary}" --connect-timeout=5 ping --silent >/dev/null 2>&1; do
        log "waiting for primary ${primary}..."
        sleep 10 & wait $!
    done

    file="$(start_file)"
    reset=0
    log "streaming binary logs from ${primary}, starting at ${file}"

    # --raw writes files identical to the primary's; --result-file is the
    # destination prefix (a directory, with trailing slash).
    mysqlbinlog --defaults-extra-file="${repl_cnf}" \
        --read-from-remote-server --host="${primary}" \
        --raw --stop-never \
        --connection-server-id="${server_id}" \
        --result-file="${binlog_dir}/" \
        "${file}" 2> "${err_file}" &
    pid=$!
    echo "${pid}" > "${pid_file}"

    # --- Watchdog -----------------------------------------------------------
    strikes=0
    while kill -0 "${pid}" 2>/dev/null; do
        sleep 60 & wait $!
        if behind; then
            strikes=$(( strikes + 1 ))
            if [ "${strikes}" -ge "${watchdog_strikes}" ]; then
                log "stream behind the replica for ${strikes} minutes, restarting it"
                kill "${pid}" 2>/dev/null
            fi
        else
            strikes=0
        fi
    done

    wait "${pid}" 2>/dev/null
    rm -f "${pid_file}"
    grep -v 'Using a password' "${err_file}" | sed 's/^/[mysql-binlog]   /'

    # --- Gap handling -------------------------------------------------------
    if grep -q 'Could not find first log file' "${err_file}"; then
        log "WARNING: ${file} was already purged on the primary. Point-in-time"
        log "recovery has a GAP until the next full backup. Restarting at the"
        log "replica's current file."
        reset=1
    fi

    log "stream stopped, reconnecting in 10s"
    sleep 10 & wait $!
done
