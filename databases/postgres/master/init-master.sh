#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres \
    --set user="${REPLICATION_USER}" --set password="${REPLICATION_PASSWORD}" <<-'EOSQL'
    CREATE ROLE :"user" WITH REPLICATION LOGIN PASSWORD :'password';
EOSQL

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres \
    --set user="${MONITOR_USER}" --set password="${MONITOR_PASSWORD}" <<-'EOSQL'
    CREATE ROLE :"user" WITH LOGIN PASSWORD :'password' CONNECTION LIMIT 5;
    GRANT pg_monitor TO :"user";
EOSQL

for db in postgres template1; do
    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${db}" <<-'EOSQL'
        CREATE EXTENSION IF NOT EXISTS pg_stat_monitor;
EOSQL
done

echo "host replication all all scram-sha-256" >> "${PGDATA}/pg_hba.conf"
