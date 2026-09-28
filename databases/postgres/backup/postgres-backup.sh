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
#                  2. runs a backup at once if none exists, then on
#                     BACKUP_SCHEDULE (cron); a failed backup is retried
#                     within the hour
#                  3. copies the data directory with the WAL needed to make it
#                     consistent (--wal-method=stream) into a work directory
#                  4. optionally verifies it against its manifest
#                     (pg_verifybackup: every file and the WAL)
#                  5. packs it into base.tar.lz4 and renames the folder only on
#                     success, so an incomplete backup is never mistaken for a
#                     good one
#                  6. prunes backups older than BACKUP_RETENTION (always
#                     keeping the newest), WAL older than the oldest kept
#                     backup, and moved-aside WAL past the retention
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
#   BACKUP_SCHEDULE        (env) cron expression of the base backups
#                          (minute hour day month weekday), in TZ.
#                          Default: 30 2 * * *
#   BACKUP_RETENTION       (env) how long backups are kept: number + h, d, w,
#                          M (months) or y. Default: 7d
#   BACKUP_VERIFY          (env) "true" verifies each backup. Default: true
#   PGPASSWORD             (env, exported) password read by the client tools
#   component              (local) log prefix: backup, or wal in the stream
#   backup_root            (local) directory holding one folder per backup
#   wal_dir                (local) WAL segments streamed from the primary
#   run_dir                (local) container-only state (lock, PID)
#   running                (local) lock file present while a backup runs
#   failed                 (local) marker left by a failed backup
#   next_file              (local) epoch of the next scheduled backup (health)
#   cron_minutes, cron_hours, cron_days, cron_months, cron_weekdays,
#   cron_any_day           (local) BACKUP_SCHEDULE expanded by parse_settings
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
schedule="${BACKUP_SCHEDULE:-30 2 * * *}"
retention="${BACKUP_RETENTION:-7d}"
verify="${BACKUP_VERIFY:-true}"
watchdog_strikes=3
export PGPASSWORD="${REPLICATION_PASSWORD:-}"

backup_root=/backups/base
wal_dir=/backups/wal
run_dir=/run/postgres-backup
running="${run_dir}/running"
failed="${run_dir}/failed"
next_file="${run_dir}/next-run"
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
# Healthy while the WAL stream runs, a backup exists, the last attempt
# did not fail and the next scheduled backup is not over an hour overdue.
if [ "${1:-}" = "health" ]; then
    [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null || exit 1
    [ -f "${running}" ] && exit 0
    [ ! -f "${failed}" ] && [ -n "$(list_backups)" ] || exit 1
    [ -f "${next_file}" ] && [ "$(date +%s)" -lt $(( $(cat "${next_file}") + 3600 )) ]
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
    cutoff="$(retention_cutoff)"
    mapfile -t backups < <(list_backups)

    for (( i = 0; i < ${#backups[@]} - 1; i++ )); do
        if [ "$(stat -c %Y "${backups[i]}/.started" 2>/dev/null || echo 0)" -lt "${cutoff}" ]; then
            log "removing expired backup ${backups[i]}"
            rm -rf "${backups[i]}"
        fi
    done
    find "${backup_root}" -maxdepth 1 -name '*.failed.log' ! -newermt "@${cutoff}" -delete
    # Logs moved aside after a primary change: kept until their newest file
    # is past the retention, like the backups they belong to.
    find "$(dirname "${wal_dir}")" -mindepth 1 -maxdepth 1 -type d -name "$(basename "${wal_dir}").*" \
        ! -newermt "@${cutoff}" -printf '[postgres-backup] removing old logs %f\n' -exec rm -rf {} +

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
    touch "${failed}"
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
    t="$(next_run)" || die "BACKUP_SCHEDULE '${schedule}' never matches within a year"
    # After a failure, or without any good backup, retry within an hour.
    if { [ -f "${failed}" ] || [ -z "$(list_backups)" ]; } && [ "${t}" -gt $(( $(date +%s) + 3600 )) ]; then
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
