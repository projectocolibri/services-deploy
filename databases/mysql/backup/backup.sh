#!/bin/bash
# ============================================================================
# MySQL backups: full + incremental XtraBackup, binary log stream
#
# Purpose:       Keeps everything needed for full and point-in-time recovery
#                of the local MySQL server (primary or replica) in /backups.
# Role:          Entrypoint of mysql-backup-primary and mysql-backup-replica
#                (compose.yaml). Layout of /backups:
#                  chains/<ts>/              one full backup and the
#                                            incrementals taken after it
#                    <ts>-full/              full backup (zstd)
#                    <ts2>-incr/             incremental: pages changed since
#                                            the previous backup of the chain
#                    server_uuid, started    server and start of the chain
#                  binlog/<server_uuid>/     binary logs of that server,
#                                            identical to its own files
#                Each server's files are kept apart by server_uuid: a
#                recreated server (new data volume) starts a new full chain
#                and a new binary log directory, never mixed with the old.
#                Startup:
#                  1. waits for the server (a replica: until it replicates)
#                  2. streams its binary logs in the background
#                     (mysqlbinlog --stop-never, restarted when it stops or
#                     falls behind for WATCHDOG_STRIKES minutes)
#                  3. takes a full backup at once if this server has none
#                  4. runs supercronic: "full" on FULL_SCHEDULE, "incr" on
#                     INCREMENTAL_SCHEDULE
#                "full" or "incr": one backup into <name>.partial, renamed
#                only when complete (and verified: decompress and prepare a
#                copy of the chain up to it), then retention. An incremental
#                without a full backup of this server is taken as full.
#                Backup operation logs are emitted to the container log only;
#                the backup volume contains recovery data and metadata, not
#                disposable log files.
#                "prepare TARGET_TIME": used by restore.sh: prepares
#                the newest backups finished before TARGET_TIME into /restore.
#                "health": the health check.
# Prerequisites: - percona/percona-xtrabackup image matching the server's major
#                  version (8.4), plus supercronic (./Dockerfile)
#                - The server's data volume mounted read-only at /var/lib/mysql
#                - Backup volume mounted at /backups; runs as root
#                - Page tracking (component_mysqlbackup, installed by the
#                  server entrypoints) makes incrementals read only the
#                  changed pages; without it they read every page
#
# Variables:
#   BACKUP_SOURCE_HOST     (env) server backed up. Default: mysql-replica
#   BACKUP_SOURCE_ROLE     (env) primary or replica. Default: replica
#   MYSQL_ROOT_PASSWORD    (env) root password of the server
#   BINLOG_SERVER_ID       (env) server ID of the stream; unique among the
#                          server's replicas and streams. Default: 101
#   FULL_SCHEDULE          (env) cron expression of the full backups.
#                          Default: 0 2 * * 0
#   INCREMENTAL_SCHEDULE   (env) cron expression of the incrementals.
#                          Default: 0 2 * * 1-6
#   RETENTION_DAYS         (env) days of point-in-time recovery kept.
#                          Default: 14
#   BACKUP_VERIFY          (env) "true" verifies each backup. Default: true
#   BACKUP_THREADS         (env) parallel copy/compression threads. Default: 2
#   component              (local) log prefix: backup, or binlog in the stream
#   chains_dir, binlog_root (local) backup chains and binary log directories
#   run_dir                (local) container-only state: credentials, lock,
#                          stream PID, status of the last backup (ok, failed)
#   root_cnf               (local) option file with the root credentials
#   chain, base, target, partial, operation_log
#                          (local) chain directory, backup the incremental
#                          builds on, final and in-progress backup directories
#   uuid                   (local) server_uuid of the server
#   cutoff                 (local) epoch before which backups may be removed
#   "$1"                   (args) full, incr, prepare, health; empty at startup
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
source_host="${BACKUP_SOURCE_HOST:-mysql-replica}"
source_role="${BACKUP_SOURCE_ROLE:-replica}"
server_id="${BINLOG_SERVER_ID:-101}"
full_schedule="${FULL_SCHEDULE:-0 2 * * 0}"
incr_schedule="${INCREMENTAL_SCHEDULE:-0 2 * * 1-6}"
retention_days="${RETENTION_DAYS:-14}"
verify="${BACKUP_VERIFY:-true}"
threads="${BACKUP_THREADS:-2}"
watchdog_strikes=5

chains_dir=/backups/chains
binlog_root=/backups/binlog
run_dir=/run/mysql-backup
root_cnf="${run_dir}/root.cnf"

component=backup

log() {
    echo "[mysql-${component}] $(date '+%F %T') $*"
}

# query SQL: runs SQL on the server and prints the result without headers.
query() {
    mysql --defaults-extra-file="${root_cnf}" --host="${source_host}" -N -B -e "$1" 2>/dev/null
}

# list_chains: chain directories with a complete full backup, oldest first.
list_chains() {
    local c
    find "${chains_dir}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/([0-9]{8}-[0-9]{6}|[0-9]{14})' 2>/dev/null | sort | while read -r c; do
        [ -d "${c}/$(basename "${c}")-full" ] && echo "${c}"
    done
}

# list_backups CHAIN: complete backups of a chain, in order.
list_backups() {
    find "$1" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/([0-9]{8}-[0-9]{6}|[0-9]{14})-(full|incr)' | sort
}

# finished DIR: epoch at which a backup finished.
finished() {
    cat "$1/finished" 2>/dev/null || echo 0
}

# newest_binlog DIR: newest binary log file in DIR (empty if none).
newest_binlog() {
    find "$1" -maxdepth 1 -type f -regex '.*\.[0-9]+' -printf '%f\n' 2>/dev/null | sort | tail -1
}

# ----------------------------------------------------------------------------
# Health check
# ----------------------------------------------------------------------------
if [ "${1:-}" = "health" ]; then
    [ -f "${run_dir}/stream.pid" ] && kill -0 "$(cat "${run_dir}/stream.pid")" 2>/dev/null || exit 1
    [ -f "${run_dir}/ok" ] && [ ! -f "${run_dir}/failed" ]
    exit $?
fi

# ============================================================================
# Prepare (verification and restore)
# ============================================================================

# prepare_backups WORK DIR...: copies the full backup DIR (first) and the
# incrementals after it to WORK, decompresses them and prepares WORK/1,
# applying each incremental in order; only the last step rolls back
# uncommitted transactions. The .zst files are deleted separately:
# --remove-original with parallel threads can process a file twice and fail.
# --defaults-file limits prepare to the backup's own settings, so it never
# looks at the server's data directory mounted at /var/lib/mysql. WORK must
# not be a hidden directory: InnoDB skips them.
prepare_backups() {
    local work="$1" n=$(( $# - 1 )) i=0 d dest args
    shift
    rm -rf "${work}"
    mkdir -p "${work}"
    for d in "$@"; do
        i=$(( i + 1 ))
        dest="${work}/${i}"
        cp -a "${d}" "${dest}" \
            && xtrabackup --decompress --parallel="${threads}" --target-dir="${dest}" \
            && find "${dest}" -name '*.zst' -delete || return 1
        args=(--prepare --target-dir="${work}/1")
        [ "${i}" -gt 1 ] && args+=(--incremental-dir="${dest}")
        [ "${i}" -lt "${n}" ] && args+=(--apply-log-only)
        xtrabackup --defaults-file="${work}/1/backup-my.cnf" "${args[@]}" || return 1
        [ "${i}" -gt 1 ] && rm -rf "${dest}"
    done
    return 0
}

# Restore: prepares into /restore the newest chain whose full backup
# finished before TARGET_TIME (UTC; empty: now), with its incrementals
# finished before it, and prints "RESTORE <server_uuid> <binlog file>": the
# binary logs to replay from.
if [ "${1:-}" = "prepare" ]; then
    target_epoch="$(date -u -d "${2:-now}" +%s)" || { echo "invalid time '${2:-}'"; exit 1; }
    chain=""
    for c in $(list_chains); do
        [ "$(finished "${c}/$(basename "${c}")-full")" -le "${target_epoch}" ] && chain="${c}"
    done
    [ -n "${chain}" ] || { echo "[mysql-restore] no backup finished before ${2:-now}"; exit 1; }
    backups=()
    for b in $(list_backups "${chain}"); do
        [ "$(finished "${b}")" -le "${target_epoch}" ] && backups+=("${b}")
    done
    echo "[mysql-restore] backups: ${backups[*]#"${chains_dir}/"}"
    prepare_backups /restore/work "${backups[@]}" > /tmp/prepare.log 2>&1 \
        || { tail -20 /tmp/prepare.log; exit 1; }
    find /restore/work/1 -mindepth 1 -maxdepth 1 -exec mv -t /restore {} +
    rm -rf /restore/work /restore/backup.log /restore/finished
    chown -R 1001:1001 /restore
    echo "RESTORE $(cat "${chain}/server_uuid") $(cut -f1 /restore/xtrabackup_binlog_info)"
    exit 0
fi

# ============================================================================
# Backups
# ============================================================================

# prune: removes a chain once the next chain's full backup finished before
# the retention cutoff (the next chain then covers the whole retention).
# Binary logs: per server, the files last written before
# its oldest remaining chain started (never the newest file); a server
# without chains, once all its files are past the cutoff.
prune() {
    local cutoff chains i next dir uuid oldest c
    cutoff=$(( $(date +%s) - retention_days * 86400 ))
    mapfile -t chains < <(list_chains)
    for (( i = 0; i < ${#chains[@]} - 1; i++ )); do
        next="${chains[i+1]}/$(basename "${chains[i+1]}")-full"
        if [ "$(finished "${next}")" -lt "${cutoff}" ]; then
            log "removing expired chain ${chains[i]}"
            rm -rf "${chains[i]}"
        fi
    done
    find "${chains_dir}" -type f -name '*.log' -delete

    for dir in "${binlog_root}"/*/; do
        [ -d "${dir}" ] || continue
        uuid="$(basename "${dir}")"
        oldest=""
        for c in $(list_chains); do
            [ "$(cat "${c}/server_uuid")" = "${uuid}" ] && { oldest="${c}"; break; }
        done
        if [ -n "${oldest}" ]; then
            find "${dir}" -maxdepth 1 -type f -regex '.*\.[0-9]+' ! -name "$(newest_binlog "${dir}")" \
                ! -newer "${oldest}/started" -printf '[mysql-backup] removing binary log %f\n' -delete
        elif [ -z "$(find "${dir}" -type f -newermt "@${cutoff}" | head -1)" ]; then
            log "removing binary logs of server ${uuid} (no backups left)"
            rm -rf "${dir}"
        fi
    done
}

# backup TYPE: full or incr.
backup() {
    local type="$1" uuid chain base start ts target partial tracking=()
    # One backup at a time (the stream may ask for a full backup too).
    exec 9> "${run_dir}/backup.lock"
    flock -n 9 || { log "another backup is running, ${type} skipped"; return 0; }

    uuid="$(query 'SELECT @@server_uuid')"
    [ -n "${uuid}" ] || { log "${source_host} not reachable, ${type} backup FAILED"; touch "${run_dir}/failed"; return 1; }
    chain="$(list_chains | tail -1)"
    if [ "${type}" = "incr" ] && { [ -z "${chain}" ] || [ "$(cat "${chain}/server_uuid")" != "${uuid}" ]; }; then
        log "no full backup of this server (${uuid}) yet: taking a full backup"
        type=full
    fi

    start=$(date +%s)
    ts="$(date -d "@${start}" +%Y%m%d%H%M%S)"
    if [ "${type}" = "full" ]; then
        chain="${chains_dir}/${ts}"
        mkdir -p "${chain}"
        echo "${uuid}" > "${chain}/server_uuid"
        touch -d "@${start}" "${chain}/started"
    else
        base="$(list_backups "${chain}" | tail -1)"
    fi
    target="${chain}/${ts}-${type}"
    partial="${target}.partial"
    [ "$(query "SELECT COUNT(*) FROM mysql.component WHERE component_urn = 'file://component_mysqlbackup'")" = "1" ] \
        && tracking=(--page-tracking)

    log "starting ${type} backup of ${source_host} into ${target}${base:+ (since $(basename "${base}"))}"
    operation_log="${run_dir}/backup.log"
    rm -f "${operation_log}"
    xtrabackup --defaults-extra-file="${root_cnf}" --backup --host="${source_host}" \
        --target-dir="${partial}" --parallel="${threads}" \
        --compress=zstd --compress-threads="${threads}" \
        "${tracking[@]}" ${base:+--incremental-basedir="${base}"} 2>&1 | tee "${operation_log}"
    local status=$?

    if [ "${status}" -eq 0 ] && [ "${verify}" = "true" ]; then
        log "verifying (decompress and prepare a copy of the chain up to this backup)"
        prepare_backups /run/mysql-backup/verify.tmp $(list_backups "${chain}") "${partial}" 2>&1 | tee -a "${operation_log}"
        status=$?
        rm -rf /run/mysql-backup/verify.tmp
    fi

    if [ "${status}" -ne 0 ]; then
        log "${type} backup FAILED, last lines:"
        tail -20 "${operation_log}"
        rm -f "${operation_log}"
        rm -rf "${partial}"
        [ "${type}" = "full" ] && rm -rf "${chain}"
        touch "${run_dir}/failed"
        return 1
    fi

    rm -f "${operation_log}"
    date +%s > "${partial}/finished"
    mv "${partial}" "${target}"
    touch "${run_dir}/ok"
    rm -f "${run_dir}/failed"
    log "${type} backup complete: ${target} ($(du -sh "${target}" | cut -f1), $(( $(date +%s) - start ))s)"
    prune
}

case "${1:-}" in
    full | incr)
        backup "$1"
        exit $?
        ;;
esac

# ============================================================================
# Binary log stream
# ============================================================================

# start_file DIR: file to stream from: the newest local copy (downloaded
# again from its beginning); if the server no longer has it, the next one it
# has (a gap: logged); with no local copy, the server's current file.
start_file() {
    local dir="$1" newest files f
    mapfile -t files < <(query 'SHOW BINARY LOGS' | cut -f1)
    [ "${#files[@]}" -gt 0 ] || return 1
    newest="$(newest_binlog "${dir}")"
    if [ -z "${newest}" ]; then
        echo "${files[-1]}"
        return 0
    fi
    for f in "${files[@]}"; do
        if [[ ! "${f}" < "${newest}" ]]; then
            [ "${f}" != "${newest}" ] && log "WARNING: ${newest} is gone from the server: point-in-time recovery has a GAP until the next full backup" >&2
            echo "${f}"
            return 0
        fi
    done
    log "WARNING: local binary logs are ahead of the server, restarting at its current file" >&2
    echo "${files[-1]}"
}

# behind DIR: succeeds when the local copy is behind the server's current
# binary log position.
behind() {
    local file pos
    read -r file pos _ < <(query 'SHOW BINARY LOG STATUS')
    [ -n "${file}" ] || return 1
    [ -f "$1/${file}" ] || return 0
    [ "$(stat -c %s "$1/${file}")" -lt "${pos}" ]
}

# stream_binlogs: streams forever; run in the background.
stream_binlogs() {
    local uuid dir file pid strikes
    component=binlog
    trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

    while true; do
        until uuid="$(query 'SELECT @@server_uuid')" && [ -n "${uuid}" ]; do
            log "waiting for ${source_host}..."
            sleep 10 & wait $!
        done
        dir="${binlog_root}/${uuid}"
        mkdir -p "${dir}"
        # A different server (recreated data volume) gets a full backup now.
        chain="$(list_chains | tail -1)"
        if [ -n "${chain}" ] && [ "$(cat "${chain}/server_uuid")" != "${uuid}" ]; then
            log "new server ${uuid}: taking a full backup now"
            /bin/bash "$0" full &
        fi

        file="$(start_file "${dir}")" || { sleep 10 & wait $!; continue; }
        log "streaming binary logs of ${source_host} from ${file} into ${dir}"
        # --raw writes files identical to the server's; --result-file is the
        # destination prefix (a directory, with trailing slash).
        mysqlbinlog --defaults-extra-file="${root_cnf}" \
            --read-from-remote-server --host="${source_host}" \
            --raw --stop-never --connection-server-id="${server_id}" \
            --result-file="${dir}/" "${file}" 2> "${run_dir}/mysqlbinlog.err" &
        pid=$!
        echo "${pid}" > "${run_dir}/stream.pid"

        # --- Watchdog -------------------------------------------------------
        strikes=0
        while kill -0 "${pid}" 2>/dev/null; do
            sleep 60 & wait $!
            if behind "${dir}"; then
                strikes=$(( strikes + 1 ))
                if [ "${strikes}" -ge "${watchdog_strikes}" ]; then
                    log "stream behind the server for ${strikes} minutes, restarting it"
                    kill "${pid}" 2>/dev/null
                fi
            else
                strikes=0
            fi
        done

        wait "${pid}" 2>/dev/null
        rm -f "${run_dir}/stream.pid"
        grep -v 'Using a password' "${run_dir}/mysqlbinlog.err" | sed 's/^/[mysql-binlog]   /'
        log "stream stopped, reconnecting in 10s"
        sleep 10 & wait $!
    done
}

# ============================================================================
# Startup
# ============================================================================
trap 'log "stopping"; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

# Credentials in an option file readable only inside this container, so the
# password is never on a command line.
mkdir -p "${run_dir}" "${chains_dir}" "${binlog_root}"
rm -f "${run_dir}/ok" "${run_dir}/failed" "${run_dir}/stream.pid"
( umask 077; printf '[client]\nuser=root\npassword="%s"\n' "${MYSQL_ROOT_PASSWORD}" > "${root_cnf}" )

# Leftovers of a backup interrupted by a stop or crash.
rm -rf "${chains_dir}"/*/*.partial /run/mysql-backup/verify.tmp
find "${chains_dir}" -type f -name '*.log' -delete
for c in "${chains_dir}"/*/; do
    [ -d "${c}" ] && [ ! -d "${c}$(basename "${c}")-full" ] && rm -rf "${c}"
done

# A replica is backed up only once it has cloned the primary and replicates.
until mysqladmin --defaults-extra-file="${root_cnf}" --host="${source_host}" ping --silent >/dev/null 2>&1 \
    && { [ "${source_role}" = "primary" ] || [ -n "$(query 'SHOW REPLICA STATUS')" ]; }; do
    log "waiting for ${source_role} ${source_host}..."
    sleep 10
done

stream_binlogs &

uuid="$(query 'SELECT @@server_uuid')"
chain="$(list_chains | tail -1)"
if [ -n "${chain}" ] && [ "$(cat "${chain}/server_uuid")" = "${uuid}" ]; then
    touch "${run_dir}/ok"
else
    log "no full backup of this server yet, taking one now"
    # In a subshell, so the backup lock is released when it ends.
    ( backup full )
fi

printf '%s /bin/bash %s full\n%s /bin/bash %s incr\n' \
    "${full_schedule}" "$0" "${incr_schedule}" "$0" > "${run_dir}/crontab"
log "full backups: ${full_schedule}; incremental backups: ${incr_schedule} (UTC)"
# -passthrough-logs: job output as is, without supercronic's wrapping.
supercronic -passthrough-logs "${run_dir}/crontab" &
# Exit (and let Docker restart the container) if either one stops.
wait -n
log "the scheduler or the stream stopped, exiting"
kill $(jobs -p) 2>/dev/null
exit 1
