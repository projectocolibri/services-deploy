#!/bin/bash
# ============================================================================
# PostgreSQL primary entrypoint wrapper
#
# Purpose:       Starts PostgreSQL as the primary through the image's normal
#                entrypoint.
# Role:          - Promotion: if this data directory used to belong to a
#                  replica (the replica's volume was attached to the primary
#                  service), removing standby.signal makes PostgreSQL end
#                  recovery and start accepting writes.
#                - Databases: once the server is up, in the background, on
#                  every start, creates APP_USER and each database in
#                  DATABASES that does not exist yet, owned by APP_USER.
#                  Existing roles, databases and their data are left
#                  untouched. The replica gets them through replication.
# Prerequisites: - Percona Distribution for PostgreSQL image (provides
#                  /entrypoint.sh, psql and pg_isready, and sets PGDATA)
#                - init: true in compose.yaml, so the background task is
#                  reaped by tini and not by the postmaster
#
# Variables:
#   PGDATA             (env, set by the image) data directory, /data/db
#   POSTGRES_USER      (env) superuser used to create roles and databases
#   POSTGRES_PASSWORD  (env) password of POSTGRES_USER
#   APP_USER           (env) application role that owns DATABASES. Empty: the
#                      databases are owned by POSTGRES_USER
#   APP_PASSWORD       (env) password of APP_USER
#   DATABASES          (env) comma-separated database names to create
#   PGPASSWORD         (env, per command) password read by psql and pg_isready
#   user, password, db, owner
#                      (psql variables, via --set) inserted with %I (quoted
#                      identifier) and %L (quoted literal) to avoid SQL
#                      injection
#   "$@"               (args) command from compose.yaml (postgres and -c
#                      settings)
# ============================================================================

# ----------------------------------------------------------------------------
# Shell options
# ----------------------------------------------------------------------------
# Exit on the first failing command.
set -e

# ----------------------------------------------------------------------------
# Promotion
# ----------------------------------------------------------------------------
# standby.signal marks a data directory as a standby; without it PostgreSQL
# starts as a primary.
if [ -f "${PGDATA}/standby.signal" ]; then
    echo "[primary] promoting: this data was a replica"
    rm -f "${PGDATA}/standby.signal"
fi

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# admin_psql [ARGS...]: runs psql as the superuser over TCP on localhost, in
# the postgres database, stopping at the first SQL error.
admin_psql() {
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -U "${POSTGRES_USER}" \
        -d postgres -v ON_ERROR_STOP=1 -q "$@"
}

# ----------------------------------------------------------------------------
# Application role and databases
# ----------------------------------------------------------------------------
# Creates APP_USER and every database in DATABASES that does not exist yet.
# Safe to run on every start.
create_databases() {
    local db dbs owner

    # The temporary server used during first-time initialization listens on
    # the local socket only, so a TCP check only succeeds on the real server.
    until PGPASSWORD="${POSTGRES_PASSWORD}" pg_isready -h 127.0.0.1 -U "${POSTGRES_USER}" -d postgres -q; do
        sleep 2
    done
    # A promoted replica accepts connections before it finishes recovery;
    # wait until it accepts writes.
    until [ "$(admin_psql -tAc 'SELECT pg_is_in_recovery()')" = "f" ]; do
        sleep 2
    done

    # Application role, created only if missing (an existing role keeps its
    # password).
    if [ -n "${APP_USER}" ]; then
        admin_psql --set user="${APP_USER}" --set password="${APP_PASSWORD}" <<'EOSQL'
SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'user', :'password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'user') \gexec
EOSQL
    fi
    owner="${APP_USER:-${POSTGRES_USER}}"

    IFS=',' read -ra dbs <<< "${DATABASES}"
    for db in "${dbs[@]}"; do
        # Ignore spaces around names and empty entries.
        db="${db//[[:space:]]/}"
        [ -n "${db}" ] || continue
        # Lowercase plain names only, so clients need no quoting.
        if [[ ! "${db}" =~ ^[a-z0-9_]+$ ]]; then
            echo "[primary] database '${db}' skipped: use only lowercase letters, digits and _"
            continue
        fi

        # The owner has every privilege on the database and its public schema.
        admin_psql --set db="${db}" --set owner="${owner}" <<'EOSQL' || continue
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'owner')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
EOSQL
        echo "[primary] database ready: ${db}"
    done
}

# Detached (double fork) so tini, not the postmaster, reaps it. Never fails the
# container: errors are only logged.
( ( create_databases || echo "[primary] creating databases failed" ) & )

# ----------------------------------------------------------------------------
# Start PostgreSQL
# ----------------------------------------------------------------------------
# Hand over to the image entrypoint (becomes the main process under tini).
exec /entrypoint.sh "$@"
