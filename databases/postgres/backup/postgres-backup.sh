#!/bin/bash
# ============================================================================
# PostgreSQL backups: startup, schedule and health check (pgBackRest)
#
# Purpose:       Runs pgBackRest on a schedule. pgBackRest itself copies the
#                files, checks them, keeps the WAL and applies the retention;
#                this script only starts it.
# Role:          Entrypoint of postgres-backup-primary,
#                postgres-backup-replica and postgres-backup-server
#                (compose.yaml), configured entirely by PGBACKREST_*
#                variables.
#                "server" (postgres-backup-server, as root): creates the TLS
#                certificates in /certs if there are none (a private CA, the
#                server's and the client's; the CA key is not kept), then
#                runs `pgbackrest server` as postgres.
#                Startup as root (postgres-backup-replica): waits until
#                /certs has ca.crt, client.crt and client.key, copies them
#                where only postgres can read them, then continues as
#                postgres.
#                Startup:
#                  1. waits for the local server
#                  2. creates the stanza (idempotent; on the replica it waits
#                     until postgres-backup-server answers). From then on the
#                     server archives its WAL into the repository
#                  3. takes a full backup at once if the repository has none
#                  4. runs supercronic: full backups on FULL_SCHEDULE,
#                     differential ones on DIFF_SCHEDULE
#                "full" or "diff": one backup (called by supercronic), up to
#                3 tries 5 minutes apart, then
#                pgbackrest verify of that backup. Expiry runs automatically
#                after each backup.
#                "health": the health check.
# Prerequisites: - pgBackRest settings in PGBACKREST_* (compose.yaml)
#                - Data, socket and repository volumes mounted
#
# Variables:
#   FULL_SCHEDULE    (env) cron expression of the full backups.
#                    Default: 0 1 * * 0
#   DIFF_SCHEDULE    (env) cron expression of the differential backups.
#                    Default: 0 1 * * 1-6
#   PGBACKREST_PG1_SOCKET_PATH, PGBACKREST_PG1_USER
#                    (env) local server, also used by the health check
#   certs_dir        (local) shared certificate directory, /certs
#                    (databases/postgres/backup/certs)
#   private_certs    (local) replica side: copy of the client certificate,
#                    owned by postgres
#   state_dir        (local) status of the last backup: ok, failed
#   crontab          (local) supercronic schedule written at startup
#   type, label      (local) backup type (full, diff) and its label
#   "$1"             (args) full, diff, health or server; empty at startup
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
full_schedule="${FULL_SCHEDULE:-0 1 * * 0}"
diff_schedule="${DIFF_SCHEDULE:-0 1 * * 1-6}"
state_dir=/tmp/postgres-backup
crontab="${state_dir}/crontab"
certs_dir=/certs
private_certs=/tmp/pgbackrest-certs

log() {
    echo "[postgres-backup] $(date '+%F %T') $*"
}

# local_sql SQL: runs SQL on the local server and prints the result.
local_sql() {
    psql --host="${PGBACKREST_PG1_SOCKET_PATH}" --username="${PGBACKREST_PG1_USER}" \
        --dbname=postgres -tAc "$1" 2>/dev/null
}

# has_backup: succeeds when the repository holds at least one backup.
has_backup() {
    pgbackrest info --output=json 2>/dev/null | grep -q '"label"'
}

# ----------------------------------------------------------------------------
# TLS certificates (postgres-backup-replica <-> postgres-backup-server)
# ----------------------------------------------------------------------------
# create_certs: creates ca.crt, server.crt/.key (CN postgres-backup-server)
# and client.crt/.key (CN pgbackrest-client, the name the server accepts) in
# /certs, valid 10 years, unless ca.crt exists. Delete them all and restart
# postgres-backup-server to replace them.
create_certs() {
    local work name cn
    [ -f "${certs_dir}/ca.crt" ] && return 0
    log "creating TLS certificates in databases/postgres/backup/certs"
    work="$(mktemp -d)"
    openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 3650 \
        -subj "/CN=pgBackRest CA" -keyout "${work}/ca.key" -out "${certs_dir}/ca.crt" 2>/dev/null || return 1
    for name in server client; do
        cn=postgres-backup-server
        [ "${name}" = "client" ] && cn=pgbackrest-client
        printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth,clientAuth\n' "${cn}" > "${work}/ext"
        openssl req -new -nodes -newkey rsa:2048 -subj "/CN=${cn}" \
            -keyout "${certs_dir}/${name}.key" -out "${work}/${name}.csr" 2>/dev/null \
            && openssl x509 -req -sha256 -days 3650 -in "${work}/${name}.csr" \
                -CA "${certs_dir}/ca.crt" -CAkey "${work}/ca.key" \
                -CAserial "${work}/ca.srl" -CAcreateserial -extfile "${work}/ext" \
                -out "${certs_dir}/${name}.crt" 2>/dev/null || return 1
    done
    rm -rf "${work}"
    chown 26:26 "${certs_dir}"/*.crt "${certs_dir}"/*.key
    chmod 600 "${certs_dir}"/*.key
    log "certificates created; for backups on another server, copy ca.crt, client.crt and"
    log "client.key to databases/postgres/backup/certs on the replica's server"
}

# postgres-backup-server: certificates, then the TLS server as postgres.
if [ "${1:-}" = "server" ]; then
    create_certs || { log "ERROR: could not create the certificates"; exit 1; }
    exec gosu postgres pgbackrest server
fi

# postgres-backup-replica starts as root: the copied certificates may belong
# to any host user, so they are copied where postgres can read them.
if [ "$(id -u)" = "0" ] && [ "${1:-}" != "health" ]; then
    until [ -f "${certs_dir}/ca.crt" ] && [ -f "${certs_dir}/client.crt" ] && [ -f "${certs_dir}/client.key" ]; do
        log "waiting for ca.crt, client.crt and client.key in databases/postgres/backup/certs"
        log "(created by postgres-backup-server on the primary's server: copy them here)"
        sleep 30
    done
    mkdir -p "${private_certs}"
    cp "${certs_dir}/ca.crt" "${certs_dir}/client.crt" "${certs_dir}/client.key" "${private_certs}/"
    chown -R 26:26 "${private_certs}"
    chmod 600 "${private_certs}/client.key"
    exec gosu postgres /bin/bash "$0" "$@"
fi

# ----------------------------------------------------------------------------
# Health check
# ----------------------------------------------------------------------------
# Healthy when a backup exists, the last one did not fail and the server's
# last WAL archive attempt did not fail (pg_stat_archiver).
if [ "${1:-}" = "health" ]; then
    [ -f "${state_dir}/ok" ] && [ ! -f "${state_dir}/failed" ] || exit 1
    [ "$(local_sql "SELECT coalesce(last_failed_time < last_archived_time, last_failed_time IS NULL) FROM pg_stat_archiver")" = "t" ]
    exit $?
fi

# ----------------------------------------------------------------------------
# One backup (scheduled job)
# ----------------------------------------------------------------------------
# backup TYPE: takes a full or diff backup and verifies it, with up to 3
# tries 5 minutes apart (a backup from the standby fails when the
# standby is briefly behind the primary). A diff backup without a full one is
# taken as full by pgBackRest.
backup() {
    local type="$1" label attempt
    for (( attempt = 1; attempt <= 3; attempt++ )); do
        log "starting ${type} backup (attempt ${attempt} of 3)"
        if pgbackrest backup --type="${type}" \
            && label="$(pgbackrest info --output=json | grep -o '"label":"[^"]*"' | tail -1 | cut -d'"' -f4)" \
            && pgbackrest verify --set="${label}"; then
            touch "${state_dir}/ok"
            rm -f "${state_dir}/failed"
            log "${type} backup ${label} complete and verified"
            return 0
        fi
        [ "${attempt}" -lt 3 ] && { log "${type} backup failed, retrying in 5 minutes"; sleep 300; }
    done
    touch "${state_dir}/failed"
    log "${type} backup FAILED"
    return 1
}

case "${1:-}" in
    full | diff)
        backup "$1"
        exit $?
        ;;
esac

# ----------------------------------------------------------------------------
# Startup
# ----------------------------------------------------------------------------
mkdir -p "${state_dir}"
rm -f "${state_dir}/ok" "${state_dir}/failed"

until pg_isready --host="${PGBACKREST_PG1_SOCKET_PATH}" --quiet; do
    log "waiting for the local server..."
    sleep 10
done

# On the replica, also waits for the primary through postgres-backup-server.
until pgbackrest stanza-create; do
    log "stanza-create failed (see above), retrying in 60s"
    sleep 60
done

if has_backup; then
    touch "${state_dir}/ok"
else
    log "no backup in the repository, taking a full backup now"
    backup full
fi

# ----------------------------------------------------------------------------
# Schedule
# ----------------------------------------------------------------------------
printf '%s /bin/bash %s full\n%s /bin/bash %s diff\n' \
    "${full_schedule}" "$0" "${diff_schedule}" "$0" > "${crontab}"
log "full backups: ${full_schedule}; differential backups: ${diff_schedule}"
# -passthrough-logs: job output as is, without supercronic's wrapping.
exec supercronic -passthrough-logs "${crontab}"
