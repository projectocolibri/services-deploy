#!/bin/bash
# ============================================================================
# PostgreSQL backups: daily base backup + continuous WAL stream
#
# Purpose:       Keeps everything needed for full and point-in-time recovery
#                of PostgreSQL in the backup directory, from one container.
# Role:          Runs on the server with the standby.
#                WAL stream (background, pg_receivewal from the primary, so it
#                works from another server through the VPN client):
#                  1. checks the primary's system identifier against the one
#                     recorded in wal/: a different primary (recreated data
#                     volume) moves the old WAL aside and asks for a base
#                     backup at once, so the two are never mixed
#                  2. creates a replication slot on the primary (once), so the
#                     primary keeps WAL this stream has not received yet, up to
#                     max_slot_wal_keep_size
#                  3. runs pg_receivewal into gzip-compressed segments; the
#                     segment being written ends in .partial
#                  4. watchdog: restarts the stream when the primary reports the
#                     slot inactive for WATCHDOG_STRIKES minutes (a silently
#                     dropped connection is otherwise never noticed)
#                  To stop streaming for good, drop the slot on the primary:
#                    SELECT pg_drop_replication_slot('<WAL_SLOT>');
#                Base backup (foreground, pg_basebackup of the standby, which
#                keeps the load off the primary):
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
#                  major version (pg_basebackup, pg_verifybackup,
#                  pg_receivewal, psql, lz4)
#                - Replication role on the primary, allowed by pg_hba for
#                  replication and normal connections (cloned to the standby)
#                - Backup directory mounted at /backups
#
# Variables:
#   BACKUP_SOURCE_HOST     (env) standby to back up. Default: postgres-replica
#   PRIMARY_HOST           (env) primary to stream from.
#                          Default: postgres-primary
#   REPLICATION_USER       (env) replication role
#   REPLICATION_PASSWORD   (env) password of REPLICATION_USER
#   WAL_SLOT               (env) replication slot name on the primary.
#                          Default: backup_wal
#   BACKUP_TIME            (env) daily start time, HH:MM in TZ. Default: 02:30
#   BACKUP_RETENTION_DAYS  (env) days to keep backups. Default: 7
#   BACKUP_VERIFY          (env) "true" verifies each backup. Default: true
#   BACKUP_MAX_AGE_HOURS   (env) health fails when the newest backup is older.
#                          Default: 26
#   PGPASSWORD             (env, exported) password read by the client tools
#   component              (local) log prefix: backup, or wal in the stream
#   backup_root            (local) directory holding one folder per backup
#   wal_dir                (local) WAL segments streamed from the primary
#   run_dir                (local) container-only state (lock, PID)
#   running                (local) lock file present while a backup runs
#   pid_file               (local) PID of the running pg_receivewal
#   sysid_file             (local) system identifier of the primary the local
#                          WAL came from
#   backup_now             (local) flag file: the stream asks for a base backup
#                          at once (after a primary change)
#   start, ts              (local) backup start time (epoch, and timestamp name)
#   target, partial, work  (local) final folder, folder being filled, raw copy
#   cutoff                 (local) epoch before which backups are pruned
#   backups, oldest        (local) complete backups (sorted), oldest kept one
#   active, strikes, pid   (local) slot state (t/f), watchdog counter, PID of
#                          pg_receivewal
#   latest, age            (local, health) newest backup and its age in seconds
#   "$1"                   (args) "health" runs the health check
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
source_host="${BACKUP_SOURCE_HOST:-postgres-replica}"
primary="${PRIMARY_HOST:-postgres-primary}"
slot="${WAL_SLOT:-backup_wal}"
backup_time="${BACKUP_TIME:-02:30}"
retention_days="${BACKUP_RETENTION_DAYS:-7}"
verify="${BACKUP_VERIFY:-true}"
max_age_hours="${BACKUP_MAX_AGE_HOURS:-26}"
watchdog_strikes=3
export PGPASSWORD="${REPLICATION_PASSWORD:-}"

backup_root=/backups/base
wal_dir=/backups/wal
run_dir=/run/postgres-backup
running="${run_dir}/running"
pid_file="${run_dir}/pg_receivewal.pid"
sysid_file="${wal_dir}/.system_identifier"
backup_now="${run_dir}/backup-now"

component=backup

log() {
    echo "[postgres-${component}] $(date '+%F %T') $*"
}

# list_backups: prints the complete backup directories, oldest first.
list_backups() {
    find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | sort
}

# ----------------------------------------------------------------------------
# Health check mode
# ----------------------------------------------------------------------------
# Healthy while the WAL stream runs and either a backup is running or the
# newest complete backup is younger than BACKUP_MAX_AGE_HOURS.
if [ "${1:-}" = "health" ]; then
    [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null || exit 1
    [ -f "${running}" ] && exit 0
    latest="$(list_backups | tail -1)"
    [ -n "${latest}" ] && [ -f "${latest}/.started" ] || exit 1
    age=$(( $(date +%s) - $(stat -c %Y "${latest}/.started") ))
    [ "${age}" -lt $(( max_age_hours * 3600 )) ]
    exit $?
fi

mkdir -p "${run_dir}" "${backup_root}" "${wal_dir}"
rm -f "${running}" "${pid_file}" "${backup_now}"

# ============================================================================
# WAL stream
# ============================================================================

# primary_sql SQL: runs SQL on the primary as the replication role.
primary_sql() {
    psql --host="${primary}" --username="${REPLICATION_USER}" --dbname=postgres --no-password \
        -tAc "$1" 2>/dev/null
}

# newest_segment: name of the newest local WAL segment, without .gz/.partial.
newest_segment() {
    find "${wal_dir}" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9A-F]{24}.*' -printf '%f\n' \
        | cut -c1-24 | sort | tail -1
}

# check_primary: records the primary's system identifier. If the local WAL
# came from another primary (its data volume was recreated), moves it to
# wal.<old id>.<date> so the new primary's WAL is never mixed with it, and
# asks for a base backup at once. The local WAL is foreign when the recorded
# identifier differs, or when its newest segment is ahead of the primary's
# current one, which the same server can never be (this also covers WAL from
# before the identifier was recorded).
check_primary() {
    local sysid old newest current foreign=0
    sysid="$(primary_sql 'SELECT system_identifier FROM pg_control_system()')"
    [ -n "${sysid}" ] || return 1
    old="$(cat "${sysid_file}" 2>/dev/null)"
    newest="$(newest_segment)"
    if [ -n "${newest}" ]; then
        current="$(primary_sql 'SELECT pg_walfile_name(pg_current_wal_lsn())')"
        [ -n "${current}" ] || return 1
        if { [ -n "${old}" ] && [ "${old}" != "${sysid}" ]; } || [[ "${newest}" > "${current}" ]]; then
            foreign=1
        fi
    fi
    if [ "${foreign}" = "1" ]; then
        local archive="${wal_dir}.${old:-unknown}.$(date +%Y%m%d-%H%M%S)"
        log "WARNING: ${primary} is a different server (system identifier ${sysid},"
        log "local WAL is from ${old:-an unrecorded server} or ahead of it). Moving it to"
        log "${archive}; delete it once its backups are no longer needed."
        mv "${wal_dir}" "${archive}"
        mkdir -p "${wal_dir}"
        # Existing backups belong to the old primary: take a new one now.
        touch "${backup_now}"
    fi
    echo "${sysid}" > "${sysid_file}"
}

# stream_wal: streams forever; run in the background.
stream_wal() {
    local active strikes pid
    component=wal
    trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

    while true; do
        until pg_isready --host="${primary}" --username="${REPLICATION_USER}" --quiet \
            && check_primary; do
            log "waiting for primary ${primary}..."
            sleep 10 & wait $!
        done

        pg_receivewal --host="${primary}" --username="${REPLICATION_USER}" --no-password \
            --slot="${slot}" --create-slot --if-not-exists 2>&1 | sed 's/^/[postgres-wal]   /'

        log "streaming WAL from ${primary} (slot ${slot})"
        # --synchronous flushes every write, so received WAL survives a crash
        # of this server; --no-loop hands reconnection to this script.
        pg_receivewal --host="${primary}" --username="${REPLICATION_USER}" --no-password \
            --directory="${wal_dir}" --slot="${slot}" \
            --compress=gzip --synchronous --no-loop &
        pid=$!
        echo "${pid}" > "${pid_file}"

        # --- Watchdog -------------------------------------------------------
        strikes=0
        while kill -0 "${pid}" 2>/dev/null; do
            sleep 60 & wait $!
            active="$(primary_sql "SELECT active FROM pg_replication_slots WHERE slot_name = '${slot}'")"
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
}

# ============================================================================
# Base backup
# ============================================================================

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
    if [ -n "${oldest}" ]; then
        find "${wal_dir}" -maxdepth 1 -type f ! -name '*.partial' ! -name '.*' ! -newer "${oldest}/.started" \
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

# next_run: epoch of the next BACKUP_TIME (today if still ahead, else tomorrow).
next_run() {
    local now t
    now=$(date +%s)
    t=$(date -d "today ${backup_time}" +%s)
    [ "${t}" -le "${now}" ] && t=$(date -d "tomorrow ${backup_time}" +%s)
    echo "${t}"
}

# ============================================================================
# Main
# ============================================================================
trap 'log "stopping"; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

# Leftovers of a backup interrupted by a stop or crash (failure logs are kept).
rm -rf "${backup_root}"/*.partial "${backup_root}"/*.work
find "${backup_root}" -maxdepth 1 -name '*.log' ! -name '*.failed.log' -delete

stream_wal &

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
