#!/bin/bash

server_id=1

query() {
    MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql --protocol=tcp -h127.0.0.1 -uroot -N -B -e "$1"
}

forget_source() {
    until MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysqladmin ping --protocol=tcp -h127.0.0.1 -uroot --silent >/dev/null 2>&1; do
        sleep 2
    done

    if [ -n "$(query "SHOW REPLICA STATUS")" ]; then
        query "STOP REPLICA; RESET REPLICA ALL;" && echo "[primary] promoted: replication settings removed"
    fi
}

forget_source &

exec /docker-entrypoint.sh "$@" --server-id="${server_id}" --skip-replica-start
