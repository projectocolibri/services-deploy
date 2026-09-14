#!/bin/bash
# Starts MySQL through the normal entrypoint and, in the background, makes this
# instance a replica of MASTER_HOST:
#   1. first start: CLONE INSTANCE from the master (copies data and users),
#      then shut down so the container restarts on the cloned data
#   2. next start: CHANGE REPLICATION SOURCE (GTID auto-position) + START REPLICA
#   3. later starts: already configured, nothing to do

query() {
    MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql --protocol=tcp -h127.0.0.1 -uroot -N -B -e "$1"
}

setup_replication() {
    # wait for the real server (the init server runs with networking disabled)
    until MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysqladmin ping --protocol=tcp -h127.0.0.1 -uroot --silent >/dev/null 2>&1; do
        sleep 2
    done

    if [ -n "$(query "SHOW REPLICA STATUS")" ]; then
        echo "[replica] replication already configured"
        return
    fi

    if [ "$(query "SELECT COUNT(*) FROM mysql.user WHERE user = '${REPLICATION_USER}'")" = "1" ]; then
        echo "[replica] cloned from ${MASTER_HOST}, starting replication"
        query "CHANGE REPLICATION SOURCE TO
                   SOURCE_HOST = '${MASTER_HOST}',
                   SOURCE_PORT = 3306,
                   SOURCE_USER = '${REPLICATION_USER}',
                   SOURCE_PASSWORD = '${REPLICATION_PASSWORD}',
                   SOURCE_AUTO_POSITION = 1,
                   GET_SOURCE_PUBLIC_KEY = 1;
               START REPLICA;" && echo "[replica] replication started"
        return
    fi

    until MYSQL_PWD="${REPLICATION_PASSWORD}" mysqladmin ping --host="${MASTER_HOST}" --user="${REPLICATION_USER}" --connect-timeout=5 >/dev/null 2>&1; do
        echo "[replica] waiting for master ${MASTER_HOST}..."
        sleep 5
    done

    echo "[replica] cloning ${MASTER_HOST}..."
    # without a supervisor process the clone ends with error 3707 (restart
    # failed) even when it succeeded: shut down and let Docker restart us
    query "SET GLOBAL clone_valid_donor_list = '${MASTER_HOST}:3306';
           CLONE INSTANCE FROM '${REPLICATION_USER}'@'${MASTER_HOST}':3306
               IDENTIFIED BY '${REPLICATION_PASSWORD}';"
    echo "[replica] clone finished, restarting on the cloned data"
    kill -TERM 1
}

setup_replication &

exec /docker-entrypoint.sh "$@"
