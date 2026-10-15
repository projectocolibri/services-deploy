#!/bin/bash
# ============================================================================
# MySQL replica entrypoint wrapper
#
# Purpose:       Starts Percona Server through the image's normal entrypoint
#                and, in the background, turns it into a replica of
#                PRIMARY_HOST.
# Role:          Each start follows one of three paths:
#                  1. First start: CLONE INSTANCE from the primary (copies data
#                     and users), then shut down so the container restarts on
#                     the cloned data.
#                  2. Start after the clone: CHANGE REPLICATION SOURCE with
#                     GTID auto-positioning, START REPLICA.
#                  3. Later starts: replication already configured, only
#                     super_read_only is turned back on.
#                Paths 2 and 3 also install the page tracking component
#                (component_mysqlbackup) for incremental backups.
# Prerequisites: - Percona Server image (provides /docker-entrypoint.sh, mysql
#                  and mysqladmin)
#                - Clone plugin loaded on both servers (compose.yaml)
#                - restart: always, so the container comes back after step 1
#
# Variables:
#   server_id             (local) MySQL server ID of the replica. Must differ
#                         from the primary's. Fixed value: 2
#   MYSQL_ROOT_PASSWORD   (env) local root password (equal to the primary's)
#   PRIMARY_HOST          (env) host to clone and follow, e.g. mysql-primary
#   REPLICATION_USER      (env) replication account on the primary
#   REPLICATION_PASSWORD  (env) password of REPLICATION_USER
#   MYSQL_PWD             (env, per command) password read by the mysql
#                         client, keeps it off the command line
#   "$@"                  (args) command from compose.yaml (mysqld and options)
# ============================================================================

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
# One primary at a time, so the ID is fixed per role.
server_id=2

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# query SQL: runs SQL as root over TCP on localhost and prints the result
# without headers (-N) in tab-separated batch format (-B).
#   $1  SQL statement(s) to execute
query() {
    MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql --protocol=tcp -h127.0.0.1 -uroot -N -B -e "$1"
}

# read_only: enables super_read_only, which blocks writes even from root.
# Set at runtime rather than as a startup option, because it would also block
# the entrypoint's first-time setup and the clone, which run as root.
read_only() {
    page_tracking
    query "SET GLOBAL super_read_only = ON;" && echo "[replica] super_read_only on"
}

# page_tracking: installs component_mysqlbackup if missing. The server then
# records which pages change, so incremental backups (mysql-backup-replica)
# read only those. INSTALL COMPONENT is not replicated, so each server
# installs it; it must run before super_read_only, which blocks it.
page_tracking() {
    [ "$(query "SELECT COUNT(*) FROM mysql.component WHERE component_urn = 'file://component_mysqlbackup'")" = "1" ]         || { query "INSTALL COMPONENT 'file://component_mysqlbackup';" && echo "[replica] page tracking installed"; }
}

# ----------------------------------------------------------------------------
# Replication setup (runs in the background)
# ----------------------------------------------------------------------------
setup_replication() {
    # --- Wait for the local server ------------------------------------------
    # The temporary server used during first-time initialization has
    # networking disabled, so a TCP ping only succeeds on the real server.
    until MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysqladmin ping --protocol=tcp -h127.0.0.1 -uroot --silent >/dev/null 2>&1; do
        sleep 2
    done

    # --- Path 3: already replicating ----------------------------------------
    if [ -n "$(query "SHOW REPLICA STATUS")" ]; then
        echo "[replica] replication already configured"
        read_only
        return
    fi

    # --- Path 2: cloned, replication not configured yet ---------------------
    # The replication account only exists locally after a successful clone,
    # because the clone copies the primary's users.
    if [ "$(query "SELECT COUNT(*) FROM mysql.user WHERE user = '${REPLICATION_USER}'")" = "1" ]; then
        echo "[replica] cloned from ${PRIMARY_HOST}, starting replication"
        # SOURCE_AUTO_POSITION: find the start point from GTIDs
        # SOURCE_CONNECT_RETRY: seconds between reconnection attempts
        # GET_SOURCE_PUBLIC_KEY: allow caching_sha2_password without TLS
        query "CHANGE REPLICATION SOURCE TO
                   SOURCE_HOST = '${PRIMARY_HOST}',
                   SOURCE_PORT = 3306,
                   SOURCE_USER = '${REPLICATION_USER}',
                   SOURCE_PASSWORD = '${REPLICATION_PASSWORD}',
                   SOURCE_AUTO_POSITION = 1,
                   SOURCE_CONNECT_RETRY = 10,
                   GET_SOURCE_PUBLIC_KEY = 1;
               START REPLICA;" && echo "[replica] replication started"
        read_only
        return
    fi

    # --- Path 1: first start, clone the primary -----------------------------
    # Wait until the primary accepts the replication account.
    until MYSQL_PWD="${REPLICATION_PASSWORD}" mysqladmin ping --host="${PRIMARY_HOST}" --user="${REPLICATION_USER}" --connect-timeout=5 >/dev/null 2>&1; do
        echo "[replica] waiting for primary ${PRIMARY_HOST}..."
        sleep 5
    done

    echo "[replica] cloning ${PRIMARY_HOST}..."
    # clone_valid_donor_list: the only host allowed to be cloned from.
    # Without a supervisor process, CLONE ends with error 3707 (restart
    # failed) even when it succeeded, so the output is not checked here.
    query "SET GLOBAL clone_valid_donor_list = '${PRIMARY_HOST}:3306';
           CLONE INSTANCE FROM '${REPLICATION_USER}'@'${PRIMARY_HOST}':3306
               IDENTIFIED BY '${REPLICATION_PASSWORD}';"
    echo "[replica] clone finished, restarting on the cloned data"
    # Stop PID 1 (mysqld); Docker restarts the container on the cloned data,
    # which then takes path 2.
    kill -TERM 1
}

setup_replication &

# ----------------------------------------------------------------------------
# Start MySQL
# ----------------------------------------------------------------------------
# Hand over to the image entrypoint (becomes PID 1) with the replica's server ID.
exec /docker-entrypoint.sh "$@" --server-id="${server_id}"
