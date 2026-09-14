#!/bin/bash
# Runs once, when the data volume is initialized.
set -e

# replication role (used by the replica and by pg_basebackup backups)
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres \
    --set user="${REPLICATION_USER}" --set password="${REPLICATION_PASSWORD}" <<-'EOSQL'
    CREATE ROLE :"user" WITH REPLICATION LOGIN PASSWORD :'password';
EOSQL

# query analytics extension for PMM (PMM connects to the "postgres" database;
# template1 makes every database created later get it too)
for db in postgres template1; do
    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${db}" <<-'EOSQL'
        CREATE EXTENSION IF NOT EXISTS pg_stat_monitor;
EOSQL
done

# allow replication connections from the network
echo "host replication all all scram-sha-256" >> "${PGDATA}/pg_hba.conf"
