#!/bin/bash
# ============================================================================
# PostgreSQL primary initialization
#
# Purpose:       Creates the replication and monitoring roles, installs the
#                query analytics extension and allows replication connections.
# Role:          Mounted into /docker-entrypoint-initdb.d/ and run once by the
#                image entrypoint, only when the data directory is initialized.
#                The replica gets all of this when it clones the primary.
# Prerequisites: - Run by the image entrypoint while the temporary
#                  initialization server is up (local socket connections)
#                - pg_stat_monitor in shared_preload_libraries (compose.yaml)
#
# Variables:
#   POSTGRES_USER         (env) superuser used to run the SQL below
#   REPLICATION_USER      (env) name of the replication role to create
#   REPLICATION_PASSWORD  (env) password of the replication role
#   MONITOR_USER          (env) name of the read-only monitoring role (PMM)
#   MONITOR_PASSWORD      (env) password of the monitoring role
#   PGDATA                (env, set by the image) data directory, /data/db
#   db                    (local, loop) database the extension is created in
#   user, password        (psql variables, via --set) role name and password,
#                         inserted with :"user" (quoted identifier) and
#                         :'password' (quoted literal) to avoid SQL injection
# ============================================================================

# ----------------------------------------------------------------------------
# Shell options
# ----------------------------------------------------------------------------
# Abort initialization on the first failing command.
set -e

# ----------------------------------------------------------------------------
# Replication role
# ----------------------------------------------------------------------------
# REPLICATION + LOGIN: allowed to run pg_basebackup and stream WAL.
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres \
    --set user="${REPLICATION_USER}" --set password="${REPLICATION_PASSWORD}" <<-'EOSQL'
    CREATE ROLE :"user" WITH REPLICATION LOGIN PASSWORD :'password';
EOSQL

# ----------------------------------------------------------------------------
# Monitoring role (PMM)
# ----------------------------------------------------------------------------
# Read-only access to statistics through the built-in pg_monitor role,
# limited to 5 connections.
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres \
    --set user="${MONITOR_USER}" --set password="${MONITOR_PASSWORD}" <<-'EOSQL'
    CREATE ROLE :"user" WITH LOGIN PASSWORD :'password' CONNECTION LIMIT 5;
    GRANT pg_monitor TO :"user";
EOSQL

# ----------------------------------------------------------------------------
# Query analytics extension
# ----------------------------------------------------------------------------
# pg_stat_monitor feeds PMM Query Analytics. PMM connects to "postgres";
# creating it in template1 makes every database created later get it too.
for db in postgres template1; do
    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${db}" <<-'EOSQL'
        CREATE EXTENSION IF NOT EXISTS pg_stat_monitor;
EOSQL
done

# ----------------------------------------------------------------------------
# Client authentication for replication
# ----------------------------------------------------------------------------
# Allow replication connections from any address with SCRAM password auth.
echo "host replication all all scram-sha-256" >> "${PGDATA}/pg_hba.conf"
