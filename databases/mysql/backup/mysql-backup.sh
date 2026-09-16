#!/bin/bash
# ============================================================================
# MySQL scheduled physical backup (Percona XtraBackup)
#
# Purpose:       Takes a daily full physical backup of the local MySQL replica,
#                verifies it and removes backups and binary logs past retention.
# Role:          Base backups for disaster recovery. Together with the binary
#                logs streamed by mysql-binlog.sh they allow point-in-time
#                recovery. Backing up the replica keeps the load off the
#                primary.
#                  1. waits for the replica to be up and replicating
#                  2. runs a backup at once if none exists, then every day at
#                     BACKUP_TIME
#                  3. writes into <timestamp>.partial and renames it only on
#                     success, so an incomplete backup is never mistaken for a
#                     good one
#                  4. optionally verifies it (decompress + prepare on a copy)
#                  5. prunes backups older than BACKUP_RETENTION_DAYS (always
#                     keeping the newest) and binary logs no longer needed
#                Called with "health", runs the health check instead.
# Prerequisites: - percona/percona-xtrabackup image matching the server's major
#                  version (8.4)
#                - The replica's data volume mounted read-only at /var/lib/mysql
#                - Backup directory mounted at /backups
#                - Runs as root (reads the data files, writes backups)
#
# Variables:
#   BACKUP_SOURCE_HOST     (env) replica to back up. Default: mysql-replica
#   MYSQL_ROOT_PASSWORD    (env) root password of the replica
#   BACKUP_TIME            (env) daily start time, HH:MM. Default: 02:00. The
#                          XtraBackup image has no time zone data: always UTC
#   BACKUP_RETENTION_DAYS  (env) days to keep backups. Default: 7
#   BACKUP_VERIFY          (env) "true" verifies each backup. Default: true
#   BACKUP_THREADS         (env) parallel copy/compression threads. Default: 2
#   BACKUP_MAX_AGE_HOURS   (env) health fails when the newest backup is older.
#                          Default: 26
#   backup_root            (local) directory holding one folder per backup
#   binlog_dir             (local) binary logs written by mysql-binlog.sh
#   run_dir                (local) container-only state (credentials, lock)
#   client_cnf             (local) option file with the root credentials
#   running                (local) lock file present while a backup runs
#   start, ts              (local) backup start time (epoch, and timestamp name)
#   target, partial        (local) final and in-progress backup directories
#   work                   (local) scratch copy used for verification
#   cutoff                 (local) epoch before which backups are pruned
#   backups, oldest        (local) complete backups (sorted), oldest kept one
#   newest_binlog          (local) binary log being written, never pruned
#   latest, age            (local, health) newest backup and its age in seconds
#   "$1"                   (args) "health" runs the health check
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
source_host="${BACKUP_SOURCE_HOST:-mysql-replica}"
backup_time="${BACKUP_TIME:-02:00}"
retention_days="${BACKUP_RETENTION_DAYS:-7}"
verify="${BACKUP_VERIFY:-true}"
threads="${BACKUP_THREADS:-2}"
max_age_hours="${BACKUP_MAX_AGE_HOURS:-26}"

backup_root=/backups/full
binlog_dir=/backups/binlog
run_dir=/run/mysql-backup
client_cnf="${run_dir}/client.cnf"
running="${run_dir}/running"

log() {
    echo "[mysql-backup] $(date '+%F %T') $*"
}

# latest_backup: prints the newest complete backup directory (empty if none).
latest_backup() {
    find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort | tail -1
}

# ----------------------------------------------------------------------------
# Health check mode
# ----------------------------------------------------------------------------
# Healthy while a backup is running, or when the newest complete backup is
# younger than BACKUP_MAX_AGE_HOURS.
if [ "${1:-}" = "health" ]; then
    [ -f "${running}" ] && exit 0
    latest="$(latest_backup)"
    [ -n "${latest}" ] && [ -f "${latest}/.started" ] || exit 1
    age=$(( $(date +%s) - $(stat -c %Y "${latest}/.started") ))
    [ "${age}" -lt $(( max_age_hours * 3600 )) ]
    exit $?
fi

# ----------------------------------------------------------------------------
# Credentials
# ----------------------------------------------------------------------------
# Option file readable only inside this container, so the password is not
# passed on the command line.
mkdir -p "${run_dir}" "${backup_root}"
rm -f "${running}"
(
    umask 077
    printf '[client]\nuser=root\npassword="%s"\n' "${MYSQL_ROOT_PASSWORD}" > "${client_cnf}"
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# wait_for_source: waits until the replica answers and replication is set up,
# so a replica that is still cloning is never backed up.
wait_for_source() {
    until mysqladmin --defaults-extra-file="${client_cnf}" --host="${source_host}" ping --silent >/dev/null 2>&1 \
        && [ -n "$(mysql --defaults-extra-file="${client_cnf}" --host="${source_host}" -N -B -e 'SHOW REPLICA STATUS' 2>/dev/null)" ]; do
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
    cutoff=$(( $(date +%s) - retention_days * 86400 ))
    mapfile -t backups < <(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}-[0-9]{6}' | sort)

    for (( i = 0; i < ${#backups[@]} - 1; i++ )); do
        if [ "$(stat -c %Y "${backups[i]}/.started" 2>/dev/null || echo 0)" -lt "${cutoff}" ]; then
            log "removing expired backup ${backups[i]}"
            rm -rf "${backups[i]}"
        fi
    done
    find "${backup_root}" -maxdepth 1 -name '*.failed.log' -mtime +"${retention_days}" -delete

    oldest="$(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}-[0-9]{6}' | sort | head -1)"
    if [ -n "${oldest}" ] && [ -d "${binlog_dir}" ]; then
        newest_binlog="$(find "${binlog_dir}" -maxdepth 1 -type f -regex '.*\.[0-9]+' -printf '%f\n' | sort | tail -1)"
        find "${binlog_dir}" -maxdepth 1 -type f -regex '.*\.[0-9]+' ! -name "${newest_binlog}" \
            ! -newer "${oldest}/.started" -printf '[mysql-backup] removing binary log %f\n' -delete
    fi
}

# ----------------------------------------------------------------------------
# Backup
# ----------------------------------------------------------------------------
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
    xtrabackup --defaults-extra-file="${client_cnf}" --backup \
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
        return 1
    fi

    if [ "${verify}" = "true" ]; then
        log "verifying backup (decompress + prepare on a copy)"
        if ! verify_backup "${partial}" >> "${partial}.log" 2>&1; then
            log "verification FAILED, last lines of the log:"
            tail -20 "${partial}.log"
            mv "${partial}.log" "${target}.failed.log"
            rm -rf "${partial}" "${running}"
            return 1
        fi
    fi

    mv "${partial}.log" "${partial}/backup.log"
    touch -d "@${start}" "${partial}/.started"
    mv "${partial}" "${target}"
    rm -f "${running}"
    log "backup complete: ${target} ($(du -sh "${target}" | cut -f1), $(( $(date +%s) - start ))s)"

    prune
}

# ----------------------------------------------------------------------------
# Scheduler
# ----------------------------------------------------------------------------
# next_run: epoch of the next BACKUP_TIME (today if still ahead, else tomorrow).
next_run() {
    local now t
    now=$(date +%s)
    t=$(date -d "today ${backup_time}" +%s)
    [ "${t}" -le "${now}" ] && t=$(date -d "tomorrow ${backup_time}" +%s)
    echo "${t}"
}

trap 'log "stopping"; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

# Leftovers of a backup interrupted by a stop or crash.
rm -rf "${backup_root}"/*.partial "${backup_root}"/*.partial.log "${backup_root}/verify.tmp"

wait_for_source
if [ -z "$(latest_backup)" ]; then
    log "no backup found, taking the first one now"
    run_backup
fi

while true; do
    t="$(next_run)"
    # Without any good backup, retry within an hour instead of waiting a day.
    if [ -z "$(latest_backup)" ] && [ "${t}" -gt $(( $(date +%s) + 3600 )) ]; then
        t=$(( $(date +%s) + 3600 ))
    fi
    log "next backup at $(date -d "@${t}" '+%F %T')"
    sleep $(( t - $(date +%s) )) & wait $!
    wait_for_source
    run_backup
done
