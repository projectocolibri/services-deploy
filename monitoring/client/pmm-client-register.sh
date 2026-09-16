#!/bin/bash

node="${PMM_AGENT_SETUP_NODE_NAME}"

echo "========================================================="
echo " Registering services of node ${node} in PMM"
echo "========================================================="

until pmm-admin status 2>/dev/null | grep -q "Connected *: true"; do
    echo "waiting for pmm-agent to connect..."
    sleep 2
done

wait_for() {
    local waited=0
    if ! getent hosts "$1" >/dev/null 2>&1; then
        echo "[$1] not running, skipping"
        return 1
    fi
    until timeout 2 bash -c "</dev/tcp/$1/$2" 2>/dev/null; do
        if [ "${waited}" -ge "${MONITOR_WAIT_TIMEOUT:-300}" ]; then
            echo "[$1] port $2 not reachable after ${waited}s, skipping"
            return 1
        fi
        echo "[$1] waiting for port $2..."
        sleep 5
        waited=$((waited + 5))
    done
}

remove() {
    pmm-admin remove "$1" "$2" >/dev/null 2>&1 || true
}

if wait_for localhost 8080; then
    remove external "cadvisor-${node}"
    pmm-admin add external --service-name="cadvisor-${node}" \
        --listen-port=8080 --group=cadvisor
fi

if [ "${MONITOR_DATABASES}" != "true" ]; then
    echo "MONITOR_DATABASES=${MONITOR_DATABASES}: databases are registered by another server"
    exit 0
fi

for host in mysql-primary mysql-replica; do
    if wait_for "${host}" 3306; then
        remove mysql "${host}"
        pmm-admin add mysql --service-name="${host}" \
            --host="${host}" --port=3306 \
            --username="${MONITOR_MYSQL_USER}" --password="${MONITOR_MYSQL_PASSWORD}" \
            --query-source=perfschema --cluster=mysql
    fi
done

for host in postgres-primary postgres-replica; do
    if wait_for "${host}" 5432; then
        remove postgresql "${host}"
        pmm-admin add postgresql --service-name="${host}" \
            --host="${host}" --port=5432 \
            --username="${MONITOR_POSTGRES_USER}" --password="${MONITOR_POSTGRES_PASSWORD}" \
            --query-source=pgstatmonitor --cluster=postgres
    fi
done
