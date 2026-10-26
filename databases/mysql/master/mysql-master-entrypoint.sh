#!/bin/bash
# ============================================================================
# MySQL primary entrypoint wrapper
#
# Purpose:       Starts Percona Server as the primary through the image's
#                normal entrypoint, with a fixed server ID.
# Role:          Once the server is up, in the background, on every start:
#                - Promotion: if this data directory used to belong to a
#                  replica (the replica's volume was attached to the primary
#                  service), its replication settings are removed, so it never
#                  follows the old primary again.
#                - Page tracking: installs component_mysqlbackup, used by
#                  incremental backups.
#                - Application access: grants MYSQL_USER all privileges on
#                  every database, without global server privileges.
#                - Databases: creates each database in DATABASES that does not
#                  exist yet. Existing databases and their data are left
#                  untouched. The replica gets them through replication.
# Prerequisites: - Percona Server image (provides /docker-entrypoint.sh, mysql
#                  and mysqladmin)
#                - MYSQL_ROOT_PASSWORD set in the container environment
#
# Variables:
#   server_id            (local) MySQL server ID of the primary. Must differ
#                        from the replica's. Fixed value: 1
#   MYSQL_ROOT_PASSWORD  (env) root password used for local admin queries
#   MYSQL_USER           (env) application user granted database access
#   DATABASES            (env) comma-separated database names to create
#   MYSQL_PWD            (env, per command) password read by the mysql client,
#                        keeps it off the command line
#   "$@"                 (args) command from compose.yaml (mysqld and options)
# ============================================================================

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
# One primary at a time, so the ID is fixed per role.
server_id=1

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# query SQL: runs SQL as root over TCP on localhost and prints the result
# without headers (-N) in tab-separated batch format (-B).
#   $1  SQL statement(s) to execute
query() {
    MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql --protocol=tcp -h127.0.0.1 -uroot -N -B -e "$1"
}

# ----------------------------------------------------------------------------
# Promotion cleanup
# ----------------------------------------------------------------------------
# Drops any replication configuration left over from when this data was a
# replica.
forget_source() {
    # SHOW REPLICA STATUS is empty on a server that never replicated.
    if [ -n "$(query "SHOW REPLICA STATUS")" ]; then
        query "STOP REPLICA; RESET REPLICA ALL;" && echo "[primary] promoted: replication settings removed"
    fi
}

# ----------------------------------------------------------------------------
# Page tracking
# ----------------------------------------------------------------------------
# Installs component_mysqlbackup if missing. The server then records which
# pages change, so incremental backups (mysql-backup-primary) read only
# those. INSTALL COMPONENT is not replicated: the replica installs its own.
page_tracking() {
    [ "$(query "SELECT COUNT(*) FROM mysql.component WHERE component_urn = 'file://component_mysqlbackup'")" = "1" ]         || { query "INSTALL COMPONENT 'file://component_mysqlbackup';" && echo "[primary] page tracking installed"; }
}

# ----------------------------------------------------------------------------
# Application databases
# ----------------------------------------------------------------------------
# Creates every database in DATABASES that does not exist yet. MYSQL_USER gets
# database-level privileges on every database, including databases created
# later, without receiving global server privileges. Safe on every start.
create_databases() {
    local db dbs

    # Remove any global grant from earlier versions, then grant all privileges
    # at the database level for every database name. The explicit grants repair
    # existing databases; the wildcard grant covers databases created later.
    if [ -n "${MYSQL_USER}" ]; then
        query "REVOKE ALL PRIVILEGES, GRANT OPTION ON *.* FROM '${MYSQL_USER}'@'%';" || return 1
        while IFS= read -r db; do
            [ -n "${db}" ] || continue
            query "GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${MYSQL_USER}'@'%';" || return 1
        done < <(query "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys')")
        query "GRANT ALL PRIVILEGES ON \`%\`.* TO '${MYSQL_USER}'@'%';" || return 1
        echo "[primary] all database privileges granted: ${MYSQL_USER}"
    fi

    IFS=',' read -ra dbs <<< "${DATABASES}"
    for db in "${dbs[@]}"; do
        # Ignore spaces around names and empty entries.
        db="${db//[[:space:]]/}"
        [ -n "${db}" ] || continue
        # Plain names only: they are inserted into SQL between backticks.
        # Lowercase, like every name on this server (--lower-case-table-names=1).
        db="${db,,}"
        if [[ ! "${db}" =~ ^[a-z0-9_%]+$ ]]; then
            echo "[primary] database '${db}' skipped: use only letters, digits, _ and %"
            continue
        fi

        # A pattern is grant-only; the wildcard database grant above already
        # covers it.
        if [[ "${db}" == *%* ]]; then
            continue
        fi

        query "CREATE DATABASE IF NOT EXISTS \`${db}\`;" || continue
        echo "[primary] database ready: ${db}"
    done
}

# ----------------------------------------------------------------------------
# Post-start tasks (run in the background)
# ----------------------------------------------------------------------------
# Waits for the real server, then runs the tasks above.
after_start() {
    # The temporary server used during first-time initialization has
    # networking disabled, so a TCP ping only succeeds on the real server.
    until MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysqladmin ping --protocol=tcp -h127.0.0.1 -uroot --silent >/dev/null 2>&1; do
        sleep 2
    done

    forget_source
    page_tracking
    create_databases || echo "[primary] application database privileges failed"
}

after_start &

# ----------------------------------------------------------------------------
# Start MySQL
# ----------------------------------------------------------------------------
# Hand over to the image entrypoint (becomes PID 1). --skip-replica-start keeps
# a promoted replica from reconnecting to the old primary before the cleanup
# above removes its settings.
exec /docker-entrypoint.sh "$@" --server-id="${server_id}" --skip-replica-start
