#!/bin/bash
# ============================================================================
# PostgreSQL scheduled base backup (pg_basebackup)
#
# Purpose:       Takes a daily base backup of the local PostgreSQL standby,
#                verifies it and removes backups and WAL past retention.
# Role:          Base backups for disaster recovery. Together with the WAL
#                streamed by postgres-wal.sh they allow point-in-time recovery.
#                Backing up the standby keeps the load off the primary.
#                  1. waits for the standby to accept replication connections
#                  2. runs a backup at once if none exists, then every day at
#                     BACKUP_TIME
#                  3. copies the data directory with the WAL needed to make it
#                     consistent (--wal-method=stream) into a work directory
#                  4. optionally verifies it against its manifest
#                     (pg_verifybackup: every file and the WAL)
#                  5. packs it into base.tar.lz4 and renames the folder only on
#                     success, so an incomplete backup is never mistaken for a
#                     good one
#                  6. prunes backups older than BACKUP_RETENTION_DAYS (always
#                     keeping the newest) and WAL no longer needed
#                Called with "health", runs the health check instead.
# Prerequisites: - Percona Distribution for PostgreSQL image of the server's
#                  major version (pg_basebackup, pg_verifybackup, lz4)
#                - Replication role and pg_hba rule (cloned from the primary)
#                - Backup directory mounted at /backups
#
# Variables:
#   BACKUP_SOURCE_HOST     (env) standby to back up. Default: postgres-replica
#   REPLICATION_USER       (env) replication role
#   REPLICATION_PASSWORD   (env) password of REPLICATION_USER
#   BACKUP_TIME            (env) daily start time, HH:MM in TZ. Default: 02:30
#   BACKUP_RETENTION_DAYS  (env) days to keep backups. Default: 7
#   BACKUP_VERIFY          (env) "true" verifies each backup. Default: true
#   BACKUP_MAX_AGE_HOURS   (env) health fails when the newest backup is older.
#                          Default: 26
#   PGPASSWORD             (env, exported) password read by the client tools
#   backup_root            (local) directory holding one folder per backup
#   wal_dir                (local) WAL written by postgres-wal.sh
#   run_dir                (local) container-only state (lock)
#   running                (local) lock file present while a backup runs
#   start, ts              (local) backup start time (epoch, and timestamp name)
#   target, partial, work  (local) final folder, folder being filled, raw copy
#   cutoff                 (local) epoch before which backups are pruned
#   backups, oldest        (local) complete backups (sorted), oldest kept one
#   latest, age            (local, health) newest backup and its age in seconds
#   "$1"                   (args) "health" runs the health check
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
source_host="${BACKUP_SOURCE_HOST:-postgres-replica}"
backup_time="${BACKUP_TIME:-02:30}"
retention_days="${BACKUP_RETENTION_DAYS:-7}"
verify="${BACKUP_VERIFY:-true}"
max_age_hours="${BACKUP_MAX_AGE_HOURS:-26}"
export PGPASSWORD="${REPLICATION_PASSWORD:-}"

backup_root=/backups/base
wal_dir=/backups/wal
run_dir=/run/postgres-backup
running="${run_dir}/running"

log() {
    echo "[postgres-backup] $(date '+%F %T') $*"
}

# list_backups: prints the complete backup directories, oldest first.
list_backups() {
    find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort
}

# ----------------------------------------------------------------------------
# Health check mode
# ----------------------------------------------------------------------------
# Healthy while a backup is running, or when the newest complete backup is
# younger than BACKUP_MAX_AGE_HOURS.
if [ "${1:-}" = "health" ]; then
    [ -f "${running}" ] && exit 0
    latest="$(list_backups | tail -1)"
    [ -n "${latest}" ] && [ -f "${latest}/.started" ] || exit 1
    age=$(( $(date +%s) - $(stat -c %Y "${latest}/.started") ))
    [ "${age}" -lt $(( max_age_hours * 3600 )) ]
    exit $?
fi

mkdir -p "${run_dir}" "${backup_root}"
rm -f "${running}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# wait_for_source: waits until the standby accepts connections.
wait_for_source() {
    until pg_isready --host="${source_host}" --username="${REPLICATION_USER}" --quiet; do
        log "waiting for standby ${source_host}..."
        sleep 10 & wait $!
    done
}

# prune: removes backups older than the retention (never the newest), then WAL
# segments completed before the oldest remaining backup started.
prune() {
    local cutoff backups oldest i
    cutoff=$(( $(date +%s) - retention_days * 86400 ))
    mapfile -t backups < <(list_backups)

    for (( i = 0; i < ${#backups[@]} - 1; i++ )); do
        if [ "$(stat -c %Y "${backups[i]}/.started" 2>/dev/null || echo 0)" -lt "${cutoff}" ]; then
            log "removing expired backup ${backups[i]}"
            rm -rf "${backups[i]}"
        fi
    done
    find "${backup_root}" -maxdepth 1 -name '*.failed.log' -mtime +"${retention_days}" -delete

    oldest="$(list_backups | head -1)"
    if [ -n "${oldest}" ] && [ -d "${wal_dir}" ]; then
        find "${wal_dir}" -maxdepth 1 -type f ! -name '*.partial' ! -newer "${oldest}/.started" \
            -printf '[postgres-backup] removing WAL %f\n' -delete
    fi
}

# fail TS LOG: keeps the log as <TS>.failed.log and removes the attempt.
fail() {
    log "backup FAILED, last lines of the log:"
    tail -20 "$2"
    mv "$2" "${backup_root}/$1.failed.log"
    rm -rf "${backup_root}/$1.partial" "${backup_root}/$1.work" "${running}"
}

# ----------------------------------------------------------------------------
# Backup
# ----------------------------------------------------------------------------
run_backup() {
    local start ts target partial work logfile
    start=$(date +%s)
    ts="$(date -d "@${start}" +%Y%m%d-%H%M%S)"
    target="${backup_root}/${ts}"
    partial="${target}.partial"
    work="${target}.work"
    logfile="${backup_root}/${ts}.log"

    touch "${running}"
    log "starting base backup of ${source_host} into ${target}"

    # Plain format, so pg_verifybackup can check it; --checkpoint=fast starts
    # at once instead of waiting for the next restartpoint on the standby.
    pg_basebackup --host="${source_host}" --username="${REPLICATION_USER}" --no-password \
        --pgdata="${work}" --format=plain \
        --wal-method=stream --checkpoint=fast \
        --label="backup ${ts}" > "${logfile}" 2>&1 &
    if ! wait $!; then
        fail "${ts}" "${logfile}"
        return 1
    fi

    if [ "${verify}" = "true" ]; then
        log "verifying backup against its manifest"
        if ! pg_verifybackup "${work}" >> "${logfile}" 2>&1; then
            fail "${ts}" "${logfile}"
            return 1
        fi
    fi

    # Pack and compress; the manifest is also kept next to the archive.
    mkdir -p "${partial}"
    cp "${work}/backup_manifest" "${partial}/backup_manifest"
    if ! tar -C "${work}" -cf - . 2>> "${logfile}" | lz4 -1 -q > "${partial}/base.tar.lz4"; then
        fail "${ts}" "${logfile}"
        return 1
    fi
    rm -rf "${work}"

    mv "${logfile}" "${partial}/backup.log"
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

# Leftovers of a backup interrupted by a stop or crash (failure logs are kept).
rm -rf "${backup_root}"/*.partial "${backup_root}"/*.work
find "${backup_root}" -maxdepth 1 -name '*.log' ! -name '*.failed.log' -delete

wait_for_source
if [ -z "$(list_backups)" ]; then
    log "no backup found, taking the first one now"
    run_backup
fi

while true; do
    t="$(next_run)"
    # Without any good backup, retry within an hour instead of waiting a day.
    if [ -z "$(list_backups)" ] && [ "${t}" -gt $(( $(date +%s) + 3600 )) ]; then
        t=$(( $(date +%s) + 3600 ))
    fi
    log "next backup at $(date -d "@${t}" '+%F %T')"
    sleep $(( t - $(date +%s) )) & wait $!
    wait_for_source
    run_backup
done
