#!/bin/bash
# Runs once, when the data volume is initialized (sourced by the entrypoint,
# which provides the "mysql" command array already logged in as root).

# replication role: used by the replica to clone this instance (BACKUP_ADMIN)
# and to stream the binary log (REPLICATION SLAVE)
"${mysql[@]}" <<-EOSQL
    CREATE USER '${REPLICATION_USER}'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
    GRANT REPLICATION SLAVE, BACKUP_ADMIN ON *.* TO '${REPLICATION_USER}'@'%';
EOSQL
