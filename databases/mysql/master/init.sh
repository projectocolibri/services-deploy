#!/bin/bash
# ============================================================================
# MySQL primary initialization
#
# Purpose:       Creates the replication and monitoring accounts on the
#                primary.
# Role:          Mounted into /docker-entrypoint-initdb.d/ and run once by the
#                Percona Server entrypoint, only when the data volume is
#                initialized. The replica gets these accounts when it clones
#                the primary.
# Prerequisites: - Sourced by the image entrypoint, which defines the "mysql"
#                  command array already logged in as root
#                - REPLICATION_USER, REPLICATION_PASSWORD, MONITOR_USER and
#                  MONITOR_PASSWORD set in the container environment
#
# Variables:
#   mysql                 (array, from the entrypoint) mysql client command
#                         connected to the initializing server as root
#   REPLICATION_USER      name of the replication account to create
#   REPLICATION_PASSWORD  password of the replication account
#   MONITOR_USER          name of the read-only monitoring account (PMM)
#   MONITOR_PASSWORD      password of the monitoring account
# ============================================================================

# ----------------------------------------------------------------------------
# Replication account
# ----------------------------------------------------------------------------
# BACKUP_ADMIN lets the replica clone this instance with CLONE INSTANCE;
# REPLICATION SLAVE lets it stream the binary log. '%' allows any host.
"${mysql[@]}" <<-EOSQL
    CREATE USER '${REPLICATION_USER}'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
    GRANT REPLICATION SLAVE, BACKUP_ADMIN ON *.* TO '${REPLICATION_USER}'@'%';
EOSQL

# ----------------------------------------------------------------------------
# Monitoring account (PMM)
# ----------------------------------------------------------------------------
# Read-only access to server status, process list, replication state and
# performance_schema query statistics, limited to 10 connections.
"${mysql[@]}" <<-EOSQL
    CREATE USER '${MONITOR_USER}'@'%' IDENTIFIED BY '${MONITOR_PASSWORD}' WITH MAX_USER_CONNECTIONS 10;
    GRANT SELECT, PROCESS, REPLICATION CLIENT, RELOAD ON *.* TO '${MONITOR_USER}'@'%';
    GRANT SELECT ON performance_schema.* TO '${MONITOR_USER}'@'%';
EOSQL
