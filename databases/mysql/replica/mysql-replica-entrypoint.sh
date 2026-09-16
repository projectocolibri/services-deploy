#!/bin/bash

server_id=2

query() {
    MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql --protocol=tcp -h127.0.0.1 -uroot -N -B -e "$1"
}

read_only() {
    query "SET GLOBAL super_read_only = ON;" && echo "[replica] super_read_only on"
}

setup_replication() {
    until MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysqladmin ping --protocol=tcp -h127.0.0.1 -uroot --silent >/dev/null 2>&1; do
        sleep 2
    done

    if [ -n "$(query "SHOW REPLICA STATUS")" ]; then
        echo "[replica] replication already configured"
        read_only
        return
    fi

    if [ "$(query "SELECT COUNT(*) FROM mysql.user WHERE user = '${REPLICATION_USER}'")" = "1" ]; then
        echo "[replica] cloned from ${PRIMARY_HOST}, starting replication"
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

    until MYSQL_PWD="${REPLICATION_PASSWORD}" mysqladmin ping --host="${PRIMARY_HOST}" --user="${REPLICATION_USER}" --connect-timeout=5 >/dev/null 2>&1; do
        echo "[replica] waiting for primary ${PRIMARY_HOST}..."
        sleep 5
    done

    echo "[replica] cloning ${PRIMARY_HOST}..."
    query "SET GLOBAL clone_valid_donor_list = '${PRIMARY_HOST}:3306';
           CLONE INSTANCE FROM '${REPLICATION_USER}'@'${PRIMARY_HOST}':3306
               IDENTIFIED BY '${REPLICATION_PASSWORD}';"
    echo "[replica] clone finished, restarting on the cloned data"
    kill -TERM 1
}

setup_replication &

exec /docker-entrypoint.sh "$@" --server-id="${server_id}"
