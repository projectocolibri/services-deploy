#!/bin/bash
# ============================================================================
# MySQL backups: daily full backup + continuous binary log stream
#
# Purpose:       Keeps everything needed for full and point-in-time recovery
#                of MySQL in the backup directory, from one container.
# Role:          Runs on the server with the replica.
#                Binary log stream (background, pulls from the primary, so it
#                works from another server through the VPN client):
#                  1. checks the primary's server_uuid against the one recorded
#                     in binlog/: a different primary (recreated data volume)
#                     moves the old binary logs aside and asks for a full
#                     backup at once, so the two are never mixed
#                  2. resumes from the newest local binary log, or starts at
#                     the file the replica is currently reading
#                  3. runs mysqlbinlog --stop-never, which writes every new
#                     event into files identical to the primary's
#                  4. watchdog: restarts the stream when it falls behind the
#                     replica for WATCHDOG_STRIKES minutes (a silently dropped
#                     connection is otherwise never noticed)
#                  5. if the primary already purged the file to resume from,
#                     logs a gap warning and restarts at the current file
#                Full backup (foreground, Percona XtraBackup of the replica,
#                which keeps the load off the primary):
#                  1. waits for the replica to be up and replicating
#                  2. runs a backup at once if none exists, then on
#                     BACKUP_SCHEDULE (cron); a failed backup is retried
#                     within the hour
#                  3. writes into <timestamp>.partial and renames it only on
#                     success, so an incomplete backup is never mistaken for a
#                     good one
#                  4. optionally verifies it (decompress + prepare on a copy)
#                  5. prunes backups older than BACKUP_RETENTION (always
#                     keeping the newest), binary logs older than the oldest
#                     kept backup, and moved-aside logs past the retention
#                Called with "health", runs the health check instead.
# Prerequisites: - percona/percona-xtrabackup image matching the server's major
#                  version (8.4); it also provides mysql, mysqladmin and
#                  mysqlbinlog
#                - The replica's data volume mounted read-only at /var/lib/mysql
#                - Replication account on the primary (REPLICATION SLAVE)
#                - Backup directory mounted at /backups
#                - Runs as root (reads the data files, writes backups)
#
# Variables:
#   BACKUP_SOURCE_HOST     (env) replica to back up. Default: mysql-replica
#   MYSQL_ROOT_PASSWORD    (env) root password of the replica
#   PRIMARY_HOST           (env) primary to stream from. Default: mysql-primary
#   REPLICATION_USER       (env) replication account on the primary
#   REPLICATION_PASSWORD   (env) password of REPLICATION_USER
#   BINLOG_SERVER_ID       (env) server ID the stream uses on the primary; must
#                          differ from every server and replica. Default: 101
#   BACKUP_SCHEDULE        (env) cron expression of the full backups
#                          (minute hour day month weekday). Default: 0 2 * * *.
#                          The XtraBackup image has no time zone data: UTC
#   BACKUP_RETENTION       (env) how long backups are kept: number + h, d, w,
#                          M (months) or y. Default: 7d
#   BACKUP_VERIFY          (env) "true" verifies each backup. Default: true
#   BACKUP_THREADS         (env) parallel copy/compression threads. Default: 2
#   component              (local) log prefix: backup, or binlog in the stream
#   backup_root            (local) directory holding one folder per backup
#   binlog_dir             (local) binary logs copied from the primary
#   run_dir                (local) container-only state (credentials, lock)
#   root_cnf, repl_cnf     (local) option files with the credentials
#   running                (local) lock file present while a backup runs
#   failed                 (local) marker left by a failed backup
#   next_file              (local) epoch of the next scheduled backup (health)
#   cron_minutes, cron_hours, cron_days, cron_months, cron_weekdays,
#   cron_any_day           (local) BACKUP_SCHEDULE expanded by parse_settings
#   pid_file, err_file     (local) PID and stderr of the running mysqlbinlog
#   uuid_file              (local) server_uuid of the primary the local binary
#                          logs came from
#   backup_now             (local) flag file: the stream asks for a full backup
#                          at once (after a primary change)
#   reset                  (local) "1" ignores local files and restarts at the
#                          replica's current file (after a gap)
#   start, ts              (local) backup start time (epoch, and timestamp name)
#   target, partial        (local) final and in-progress backup directories
#   cutoff                 (local) epoch before which backups are pruned
#   backups, oldest        (local) complete backups (sorted), oldest kept one
#   newest_binlog          (local) binary log being written, never pruned
#   file, pos, local_size  (local) replica's read position, local copy's size
#   strikes, pid           (local) watchdog counter, PID of mysqlbinlog
#   latest, age            (local, health) newest backup and its age in seconds
#   "$1"                   (args) "health" runs the health check
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
source_host="${BACKUP_SOURCE_HOST:-mysql-replica}"
primary="${PRIMARY_HOST:-mysql-primary}"
server_id="${BINLOG_SERVER_ID:-101}"
schedule="${BACKUP_SCHEDULE:-0 2 * * *}"
retention="${BACKUP_RETENTION:-7d}"
verify="${BACKUP_VERIFY:-true}"
threads="${BACKUP_THREADS:-2}"
watchdog_strikes=5

backup_root=/backups/full
binlog_dir=/backups/binlog
run_dir=/run/mysql-backup
root_cnf="${run_dir}/root.cnf"
repl_cnf="${run_dir}/replication.cnf"
running="${run_dir}/running"
failed="${run_dir}/failed"
next_file="${run_dir}/next-run"
pid_file="${run_dir}/mysqlbinlog.pid"
err_file="${run_dir}/mysqlbinlog.err"
uuid_file="${binlog_dir}/.server_uuid"
backup_now="${run_dir}/backup-now"

component=backup

log() {
    echo "[mysql-${component}] $(date '+%F %T') $*"
}

# latest_backup: prints the newest complete backup directory (empty if none).
latest_backup() {
    find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort | tail -1
}

# ----------------------------------------------------------------------------
# Health check mode
# ----------------------------------------------------------------------------
# Healthy while the binary log stream runs, a backup exists, the last attempt
# did not fail and the next scheduled backup is not over an hour overdue.
if [ "${1:-}" = "health" ]; then
    [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null || exit 1
    [ -f "${running}" ] && exit 0
    [ ! -f "${failed}" ] && [ -n "$(latest_backup)" ] || exit 1
    [ -f "${next_file}" ] && [ "$(date +%s)" -lt $(( $(cat "${next_file}") + 3600 )) ]
    exit $?
fi

# ----------------------------------------------------------------------------
# Credentials
# ----------------------------------------------------------------------------
# Option files readable only inside this container, so the passwords are not
# passed on the command line.
mkdir -p "${run_dir}" "${backup_root}" "${binlog_dir}"
rm -f "${running}" "${pid_file}" "${backup_now}"
(
    umask 077
    printf '[client]\nuser=root\npassword="%s"\n' "${MYSQL_ROOT_PASSWORD}" > "${root_cnf}"
    printf '[client]\nuser=%s\npassword="%s"\n' "${REPLICATION_USER}" "${REPLICATION_PASSWORD}" > "${repl_cnf}"
)

# ============================================================================
# Binary log stream
# ============================================================================

# replica_field NAME: prints a field of the local replica's SHOW REPLICA STATUS.
replica_field() {
    mysql --defaults-extra-file="${root_cnf}" --host="${source_host}" -e 'SHOW REPLICA STATUS\G' 2>/dev/null \
        | awk -F': ' -v k="$1" '{ gsub(/^ +/, "", $1) } $1 == k { print $2 }'
}

# newest_local: prints the newest binary log already copied (empty if none).
newest_local() {
    find "${binlog_dir}" -maxdepth 1 -type f -regex '.*\.[0-9]+' -printf '%f\n' | sort | tail -1
}

# check_primary: records the primary's server_uuid. If the local binary logs
# came from another primary (its data volume was recreated), moves them to
# binlog.<old uuid>.<date> so the new primary's files never overwrite or mix
# with them, and asks for a full backup at once. The local files are foreign
# when the recorded uuid differs, or when the newest is ahead of the primary's
# current file (read from the replica), which the same server can never be
# (this also covers files from before the uuid was recorded).
check_primary() {
    local uuid old newest current foreign=0
    uuid="$(mysql --defaults-extra-file="${repl_cnf}" --host="${primary}" -N -B -e 'SELECT @@server_uuid' 2>/dev/null)"
    [ -n "${uuid}" ] || return 1
    old="$(cat "${uuid_file}" 2>/dev/null)"
    newest="$(newest_local)"
    if [ -n "${newest}" ]; then
        current="$(replica_field Source_Log_File)"
        # Without a recorded uuid the replica must answer; with one, a replica
        # still starting does not hold up the stream.
        [ -n "${current}" ] || [ -n "${old}" ] || return 1
        if { [ -n "${old}" ] && [ "${old}" != "${uuid}" ]; } \
            || { [ -n "${current}" ] && [[ "${newest}" > "${current}" ]]; }; then
            foreign=1
        fi
    fi
    if [ "${foreign}" = "1" ]; then
        local archive="${binlog_dir}.${old:-unknown}.$(date +%Y%m%d-%H%M%S)"
        log "WARNING: ${primary} is a different server (server_uuid ${uuid}, local"
        log "binary logs are from ${old:-an unrecorded server} or ahead of it). Moving them to"
        log "${archive}; delete it once its backups are no longer needed."
        mv "${binlog_dir}" "${archive}"
        mkdir -p "${binlog_dir}"
        # Existing backups belong to the old primary: take a new one now.
        touch "${backup_now}"
    fi
    echo "${uuid}" > "${uuid_file}"
}

# start_file: file to start streaming from: the newest local copy (downloaded
# again from its beginning), or the file the replica is reading.
start_file() {
    local file
    file="$(newest_local)"
    if [ "${reset}" = "1" ] || [ -z "${file}" ]; then
        until file="$(replica_field Source_Log_File)" && [ -n "${file}" ]; do
            log "waiting for replica ${source_host} to report its source binary log..."
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

# stream_binlogs: streams forever; run in the background.
stream_binlogs() {
    local reset=0 file pid strikes
    component=binlog
    trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

    while true; do
        until mysqladmin --defaults-extra-file="${repl_cnf}" --host="${primary}" --connect-timeout=5 ping --silent >/dev/null 2>&1 \
            && check_primary; do
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

        # --- Watchdog -------------------------------------------------------
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

        # --- Gap handling ---------------------------------------------------
        if grep -q 'Could not find first log file' "${err_file}"; then
            log "WARNING: ${file} was already purged on the primary. Point-in-time"
            log "recovery has a GAP until the next full backup. Restarting at the"
            log "replica's current file."
            reset=1
        fi

        log "stream stopped, reconnecting in 10s"
        sleep 10 & wait $!
    done
}

# ============================================================================
# Full backup
# ============================================================================

# wait_for_source: waits until the replica answers and replication is set up,
# so a replica that is still cloning is never backed up.
wait_for_source() {
    until mysqladmin --defaults-extra-file="${root_cnf}" --host="${source_host}" ping --silent >/dev/null 2>&1 \
        && [ -n "$(mysql --defaults-extra-file="${root_cnf}" --host="${source_host}" -N -B -e 'SHOW REPLICA STATUS' 2>/dev/null)" ]; do
        log "waiting for replica ${source_host}..."
        sleep 10 & wait $!
    done
}

# verify_backup DIR: decompresses and prepares a copy of DIR, which replays the
# redo log exactly as a restore would. The copy is removed afterwards. Its
# directory must not be hidden: InnoDB skips hidden directories.
# The .zst files are deleted separately: --remove-original with parallel
# threads can process a file twice and fail. --defaults-file limits prepare to
# the backup's own settings, so it never looks at the replica's data directory
# mounted at /var/lib/mysql.
verify_backup() {
    local work="${backup_root}/verify.tmp"
    rm -rf "${work}"
    cp -a "$1" "${work}" \
        && xtrabackup --decompress --parallel="${threads}" --target-dir="${work}" \
        && find "${work}" -name '*.zst' -delete \
        && xtrabackup --defaults-file="${work}/backup-my.cnf" --prepare --target-dir="${work}"
    local status=$?
    rm -rf "${work}"
    return ${status}
}

# prune: removes backups older than the retention (never the newest), then
# binary logs fully written before the oldest remaining backup started.
prune() {
    local cutoff backups oldest newest_binlog i
    cutoff="$(retention_cutoff)"
    mapfile -t backups < <(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}-[0-9]{6}' | sort)

    for (( i = 0; i < ${#backups[@]} - 1; i++ )); do
        if [ "$(stat -c %Y "${backups[i]}/.started" 2>/dev/null || echo 0)" -lt "${cutoff}" ]; then
            log "removing expired backup ${backups[i]}"
            rm -rf "${backups[i]}"
        fi
    done
    find "${backup_root}" -maxdepth 1 -name '*.failed.log' ! -newermt "@${cutoff}" -delete
    # Logs moved aside after a primary change: kept until their newest file
    # is past the retention, like the backups they belong to.
    find "$(dirname "${binlog_dir}")" -mindepth 1 -maxdepth 1 -type d -name "$(basename "${binlog_dir}").*" \
        ! -newermt "@${cutoff}" -printf '[mysql-backup] removing old logs %f\n' -exec rm -rf {} +

    oldest="$(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}-[0-9]{6}' | sort | head -1)"
    if [ -n "${oldest}" ]; then
        newest_binlog="$(newest_local)"
        find "${binlog_dir}" -maxdepth 1 -type f -regex '.*\.[0-9]+' ! -name "${newest_binlog}" \
            ! -newer "${oldest}/.started" -printf '[mysql-backup] removing binary log %f\n' -delete
    fi
}

run_backup() {
    local start ts target partial
    start=$(date +%s)
    ts="$(date -d "@${start}" +%Y%m%d-%H%M%S)"
    target="${backup_root}/${ts}"
    partial="${target}.partial"

    touch "${running}"
    log "starting full backup of ${source_host} into ${target}"

    # --slave-info records the replica's replication coordinates (GTIDs) in
    # the backup; zstd compression is applied per file while copying.
    xtrabackup --defaults-extra-file="${root_cnf}" --backup \
        --host="${source_host}" \
        --target-dir="${partial}" \
        --parallel="${threads}" \
        --compress=zstd --compress-threads="${threads}" \
        --slave-info > "${partial}.log" 2>&1 &
    if ! wait $!; then
        log "backup FAILED, last lines of the log:"
        tail -20 "${partial}.log"
        mv "${partial}.log" "${target}.failed.log"
        rm -rf "${partial}" "${running}"
        touch "${failed}"
        return 1
    fi

    if [ "${verify}" = "true" ]; then
        log "verifying backup (decompress + prepare on a copy)"
        if ! verify_backup "${partial}" >> "${partial}.log" 2>&1; then
            log "verification FAILED, last lines of the log:"
            tail -20 "${partial}.log"
            mv "${partial}.log" "${target}.failed.log"
            rm -rf "${partial}" "${running}"
            touch "${failed}"
            return 1
        fi
    fi

    mv "${partial}.log" "${partial}/backup.log"
    touch -d "@${start}" "${partial}/.started"
    mv "${partial}" "${target}"
    rm -f "${running}" "${failed}"
    log "backup complete: ${target} ($(du -sh "${target}" | cut -f1), $(( $(date +%s) - start ))s)"

    prune
}

# ============================================================================
# Schedule and retention
# ============================================================================

# die MESSAGE: logs a configuration error and stops the container.
die() {
    log "ERROR: $*"
    exit 1
}

# cron_field SPEC MIN MAX: prints the values a cron field allows, separated by
# spaces: *, n, a-b, */s, a-b/s, n/s and comma lists of these. Fails on
# anything else or on values outside MIN-MAX.
cron_field() {
    local parts part range step lo hi v out=""
    IFS=, read -ra parts <<< "$1"
    [ "${#parts[@]}" -gt 0 ] || return 1
    for part in "${parts[@]}"; do
        range="${part%/*}"
        step=1
        [ "${part}" != "${range}" ] && step="${part#*/}"
        case "${range}" in
            '*') lo=$2; hi=$3 ;;
            *-*) lo="${range%-*}"; hi="${range#*-}" ;;
            *) lo="${range}"; hi="${range}"; [ "${part}" != "${range}" ] && hi=$3 ;;
        esac
        [[ "${lo}" =~ ^[0-9]+$ && "${hi}" =~ ^[0-9]+$ && "${step}" =~ ^[0-9]+$ ]] || return 1
        [ "${step}" -gt 0 ] && [ "${lo}" -ge "$2" ] && [ "${hi}" -le "$3" ] && [ "${lo}" -le "${hi}" ] || return 1
        for (( v = 10#${lo}; v <= 10#${hi}; v += 10#${step} )); do
            out+=" ${v}"
        done
    done
    echo "${out}" | tr ' ' '\n' | sed '/^$/d' | sort -n -u | tr '\n' ' '
}

# in_list LIST VALUE: succeeds when VALUE is one of the space-separated LIST.
in_list() {
    [[ " $1 " == *" $2 "* ]]
}

# parse_settings: checks BACKUP_SCHEDULE and BACKUP_RETENTION and expands the
# schedule into cron_minutes, cron_hours, cron_days, cron_months and
# cron_weekdays (Sunday is 0; 7 is accepted for Sunday too).
parse_settings() {
    local min hour dom mon dow extra
    read -r min hour dom mon dow extra <<< "${schedule}"
    [ -n "${dow}" ] && [ -z "${extra}" ] \
        || die "BACKUP_SCHEDULE '${schedule}' must have 5 fields: minute hour day-of-month month day-of-week"
    cron_minutes="$(cron_field "${min}" 0 59)" || die "BACKUP_SCHEDULE: invalid minute '${min}'"
    cron_hours="$(cron_field "${hour}" 0 23)" || die "BACKUP_SCHEDULE: invalid hour '${hour}'"
    cron_days="$(cron_field "${dom}" 1 31)" || die "BACKUP_SCHEDULE: invalid day of month '${dom}'"
    cron_months="$(cron_field "${mon}" 1 12)" || die "BACKUP_SCHEDULE: invalid month '${mon}'"
    cron_weekdays="$(cron_field "${dow}" 0 7)" || die "BACKUP_SCHEDULE: invalid day of week '${dow}'"
    in_list "${cron_weekdays}" 7 && cron_weekdays+=" 0"
    # Standard cron: when both day fields are restricted, either may match.
    cron_any_day=0
    [[ "${dom}" == \** ]] && cron_any_day=1
    [[ "${dow}" == \** ]] && cron_any_day=$(( cron_any_day + 2 ))
    [[ "${retention}" =~ ^[1-9][0-9]*[hdwMy]$ ]] \
        || die "BACKUP_RETENTION '${retention}' must be a number and a unit: h, d, w, M or y (e.g. 7d, 1M)"
}

# day_matches DOM MONTH WEEKDAY: succeeds when BACKUP_SCHEDULE allows that day.
day_matches() {
    in_list "${cron_months}" "$2" || return 1
    case "${cron_any_day}" in
        3) return 0 ;;
        1) in_list "${cron_weekdays}" "$3" ;;
        2) in_list "${cron_days}" "$1" ;;
        *) in_list "${cron_days}" "$1" || in_list "${cron_weekdays}" "$3" ;;
    esac
}

# next_run: epoch of the next time BACKUP_SCHEDULE matches, within a year.
next_run() {
    local now day d dom mon dow h m t
    now=$(date +%s)
    for (( day = 0; day <= 366; day++ )); do
        read -r d dom mon dow <<< "$(date -d "today +${day} days" '+%F %-d %-m %w')"
        day_matches "${dom}" "${mon}" "${dow}" || continue
        for h in ${cron_hours}; do
            for m in ${cron_minutes}; do
                t=$(date -d "${d} ${h}:${m}" +%s)
                if [ "${t}" -gt "${now}" ]; then
                    echo "${t}"
                    return 0
                fi
            done
        done
    done
    return 1
}

# retention_cutoff: epoch before which backups are pruned (BACKUP_RETENTION
# ago; M is a calendar month).
retention_cutoff() {
    local unit
    case "${retention: -1}" in
        h) unit=hours ;;
        d) unit=days ;;
        w) unit=weeks ;;
        M) unit=months ;;
        y) unit=years ;;
    esac
    date -d "now - ${retention%?} ${unit}" +%s
}

# ============================================================================
# Main
# ============================================================================
trap 'log "stopping"; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT
parse_settings
rm -f "${failed}" "${next_file}"

# Leftovers of a backup interrupted by a stop or crash.
rm -rf "${backup_root}"/*.partial "${backup_root}"/*.partial.log "${backup_root}/verify.tmp"

stream_binlogs &

wait_for_source
if [ -z "$(latest_backup)" ]; then
    log "no backup found, taking the first one now"
    run_backup
fi

while true; do
    t="$(next_run)" || die "BACKUP_SCHEDULE '${schedule}' never matches within a year"
    # After a failure, or without any good backup, retry within an hour.
    if { [ -f "${failed}" ] || [ -z "$(latest_backup)" ]; } && [ "${t}" -gt $(( $(date +%s) + 3600 )) ]; then
        t=$(( $(date +%s) + 3600 ))
    fi
    echo "${t}" > "${next_file}"
    log "next backup at $(date -d "@${t}" '+%F %T')"
    # Checks every minute whether the stream asked for a backup at once.
    while [ "$(date +%s)" -lt "${t}" ] && [ ! -f "${backup_now}" ]; do
        sleep 60 & wait $!
    done
    if [ -f "${backup_now}" ]; then
        rm -f "${backup_now}"
        log "new primary detected, taking a backup now"
    fi
    wait_for_source
    run_backup
done
