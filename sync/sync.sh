#!/bin/bash
# ============================================================================
# Off-site sync: copies Docker volumes and data folders with rclone
#
# Purpose:       Copies each entry of SYNC_VOLUMES (a volume, or a folder
#                inside SYNC_DATA_DIR) to SYNC_DESTINATION/<name> without
#                ever deleting on the destination, optionally encrypted, and
#                brings copies back.
# Role:          Entrypoint of the sync service (compose.yaml).
#                Startup: copies once, then runs "run" on SYNC_SCHEDULE with
#                supercronic.
#                "run": for each entry, `rclone copy` into
#                  <destination>/<name> (a volume's name, or a folder's path
#                  inside SYNC_DATA_DIR); a file that changed here is uploaded
#                  again and its previous version moved to
#                  <destination>/_versions/<date>/<name>. Then, with
#                  SYNC_MAX_AGE, `rclone delete --min-age` removes files
#                  older than that from the whole destination (files are
#                  dated by their modification time here, which rclone
#                  keeps).
#                "config": `rclone config`, to create the remote (e.g. Google
#                  Drive) in /config/rclone/rclone.conf.
#                "restore NAME": copies <destination>/NAME back into /restore
#                  (a volume mounted by `docker compose run -v`).
#                "health": the health check.
# Prerequisites: - Docker's volume directory mounted read-only at /volumes,
#                  and SYNC_DATA_DIR at /data
#                - rclone remotes in RCLONE_CONFIG when the destination uses
#                  one
#
# Variables:
#   SYNC_DESTINATION       (env) rclone destination, e.g. gdrive:backups/server-a.
#                          Required
#   SYNC_VOLUMES           (env) comma-separated entries: volume names (with or
#                          without the PROJECT_NAME_ prefix), or folders inside
#                          SYNC_DATA_DIR (full path, or relative to it).
#                          Required
#   SYNC_DATA_DIR          (env) host folder mounted at /data, as written in
#                          .env (to recognize full paths)
#   SYNC_SCHEDULE          (env) cron expression. Default: 0 5 * * *
#   SYNC_MAX_AGE           (env) rclone age (e.g. 90d) of the files removed from
#                          the destination. Default: empty (never)
#   SYNC_ENCRYPT_PASSWORD  (env) rclone crypt password. Empty: not encrypted
#   SYNC_ENCRYPT_SALT      (env) rclone crypt salt (password2). Optional
#   SYNC_RCLONE_FLAGS      (env) extra rclone flags, split on spaces
#   PROJECT_NAME           (env) Compose project, the volume name prefix
#   state_dir              (local) status of the last run: ok, failed
#   base                   (local) destination root, wrapped in crypt when
#                          encrypted
#   stamp                  (local) date of this run, names _versions/<stamp>
#   "$1", "$2"             (args) run, config, restore NAME, health; empty at
#                          startup
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
destination="${SYNC_DESTINATION:-}"
schedule="${SYNC_SCHEDULE:-0 5 * * *}"
max_age="${SYNC_MAX_AGE:-}"
read -ra extra_flags <<< "${SYNC_RCLONE_FLAGS:-}"
state_dir=/tmp/sync

log() {
    echo "[sync] $(date '+%F %T') $*"
}

# ----------------------------------------------------------------------------
# Health check
# ----------------------------------------------------------------------------
if [ "${1:-}" = "health" ]; then
    [ -f "${state_dir}/ok" ] && [ ! -f "${state_dir}/failed" ]
    exit $?
fi

if [ "${1:-}" = "config" ]; then
    exec rclone config
fi

[ -n "${destination}" ] || { log "ERROR: SYNC_DESTINATION is not set"; exit 1; }
# An empty configuration is enough for destinations without a remote (and
# keeps rclone from warning that it is missing).
[ -f "${RCLONE_CONFIG}" ] || touch "${RCLONE_CONFIG}"

# ----------------------------------------------------------------------------
# Destination
# ----------------------------------------------------------------------------
# With a password, every path goes through an on-the-fly crypt remote that
# wraps the destination: contents and names are encrypted there.
base="${destination}"
if [ -n "${SYNC_ENCRYPT_PASSWORD:-}" ]; then
    base=":crypt,remote=\"${destination}\",password=$(rclone obscure "${SYNC_ENCRYPT_PASSWORD}")"
    [ -n "${SYNC_ENCRYPT_SALT:-}" ] && base+=",password2=$(rclone obscure "${SYNC_ENCRYPT_SALT}")"
    base+=":"
fi

# at PATH: PATH inside the destination.
at() {
    case "${base}" in
        *:) echo "${base}$1" ;;
        *) echo "${base}/$1" ;;
    esac
}

# Common rclone flags: no symbolic links (pgBackRest's "latest"), a one-line
# summary per volume, and SYNC_RCLONE_FLAGS.
flags=(--skip-links --stats 0 --stats-one-line --stats-log-level NOTICE "${extra_flags[@]}")

# ----------------------------------------------------------------------------
# Restore
# ----------------------------------------------------------------------------
if [ "${1:-}" = "restore" ]; then
    [ -n "${2:-}" ] || { log "usage: restore <name>  (with a volume mounted at /restore)"; exit 1; }
    [ -d /restore ] || { log "mount the target volume at /restore: docker compose run --rm -v <volume>:/restore sync restore $2"; exit 1; }
    log "restoring ${destination}/$2 into /restore"
    rclone copy "$(at "$2")" /restore "${flags[@]}"
    exit $?
fi

# ----------------------------------------------------------------------------
# Copy
# ----------------------------------------------------------------------------
# resolve ENTRY: sets src (directory to copy) and name (its folder on the
# destination) for a SYNC_VOLUMES entry. Without "/" it is a volume; with
# one, a folder inside SYNC_DATA_DIR, given as a full host path (Windows
# paths too, any case and slashes) or relative to SYNC_DATA_DIR.
resolve() {
    local entry="${1//\\//}" root="${SYNC_DATA_DIR:-}"
    root="${root//\\//}"
    root="${root%/}"
    if [[ "${entry}" != */* ]]; then
        name="${entry}"
        src="/volumes/${entry}/_data"
        [ -d "${src}" ] || src="/volumes/${PROJECT_NAME}_${entry}/_data"
        [ -d "${src}" ] || { log "ERROR: volume ${entry} (or ${PROJECT_NAME}_${entry}) not found"; return 1; }
        return 0
    fi
    if [ -n "${root}" ] && [[ "${entry,,}" == "${root,,}"/* ]]; then
        entry="${entry:${#root}+1}"
    elif [[ "${entry}" == /* || "${entry}" =~ ^[A-Za-z]:/ ]]; then
        log "ERROR: ${entry} is not inside SYNC_DATA_DIR (${SYNC_DATA_DIR:-not set})"
        return 1
    fi
    name="${entry#./}"
    name="${name%/}"
    src="/data/${name}"
    [ -d "${src}" ] || { log "ERROR: folder ${name} not found in SYNC_DATA_DIR"; return 1; }
}

# sync_all: copies every entry, then applies SYNC_MAX_AGE. A missing entry or
# a failed copy fails the run; the other entries are still copied.
sync_all() {
    local entries entry name src stamp status=0
    stamp="$(date +%Y%m%d-%H%M%S)"
    IFS=',' read -ra entries <<< "${SYNC_VOLUMES:-}"
    [ "${#entries[@]}" -gt 0 ] || { log "ERROR: SYNC_VOLUMES is empty"; return 1; }

    for entry in "${entries[@]}"; do
        # Trim spaces around the entry (folders may contain spaces).
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [ -n "${entry}" ] || continue
        resolve "${entry}" || { status=1; continue; }
        log "copying ${name} to ${destination}/${name}"
        rclone copy "${src}" "$(at "${name}")" \
            --backup-dir "$(at "_versions/${stamp}/${name}")" "${flags[@]}" || status=1
    done

    if [ -n "${max_age}" ]; then
        log "removing files older than ${max_age} from ${destination}"
        rclone delete "$(at "")" --min-age "${max_age}" "${flags[@]}" \
            && rclone rmdirs "$(at "")" --leave-root "${flags[@]}" || status=1
    fi
    return "${status}"
}

# run: one sync, recording its status for the health check.
run() {
    mkdir -p "${state_dir}"
    if sync_all; then
        touch "${state_dir}/ok"
        rm -f "${state_dir}/failed"
        log "sync complete"
    else
        touch "${state_dir}/failed"
        log "sync FAILED (see above)"
        return 1
    fi
}

if [ "${1:-}" = "run" ]; then
    run
    exit $?
fi

# ----------------------------------------------------------------------------
# Startup
# ----------------------------------------------------------------------------
rm -f "${state_dir}/ok" "${state_dir}/failed"
run
printf '%s /bin/bash %s run\n' "${schedule}" "$0" > /tmp/crontab
log "next copies: ${schedule}"
# -passthrough-logs: job output as is, without supercronic's wrapping.
exec supercronic -passthrough-logs /tmp/crontab
