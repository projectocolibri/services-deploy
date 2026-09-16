#!/bin/bash
# ============================================================================
# MySQL primary entrypoint wrapper
#
# Purpose:       Starts Percona Server as the primary through the image's
#                normal entrypoint, with a fixed server ID.
# Role:          Supports promotion: if this data directory used to belong to
#                a replica (the replica's volume was attached to the primary
#                service), its replication settings are removed in the
#                background once the server is up, so it never follows the old
#                primary again.
# Prerequisites: - Percona Server image (provides /docker-entrypoint.sh, mysql
#                  and mysqladmin)
#                - MYSQL_ROOT_PASSWORD set in the container environment
#
# Variables:
#   server_id            (local) MySQL server ID of the primary. Must differ
#                        from the replica's. Fixed value: 1
#   MYSQL_ROOT_PASSWORD  (env) root password used for local admin queries
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
# Promotion cleanup (runs in the background)
# ----------------------------------------------------------------------------
# Waits for the real server, then drops any replication configuration left
# over from when this data was a replica.
forget_source() {
    # The temporary server used during first-time initialization has
    # networking disabled, so a TCP ping only succeeds on the real server.
    until MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysqladmin ping --protocol=tcp -h127.0.0.1 -uroot --silent >/dev/null 2>&1; do
        sleep 2
    done

    # SHOW REPLICA STATUS is empty on a server that never replicated.
    if [ -n "$(query "SHOW REPLICA STATUS")" ]; then
        query "STOP REPLICA; RESET REPLICA ALL;" && echo "[primary] promoted: replication settings removed"
    fi
}

forget_source &

# ----------------------------------------------------------------------------
# Start MySQL
# ----------------------------------------------------------------------------
# Hand over to the image entrypoint (becomes PID 1). --skip-replica-start keeps
# a promoted replica from reconnecting to the old primary before the cleanup
# above removes its settings.
exec /docker-entrypoint.sh "$@" --server-id="${server_id}" --skip-replica-start
