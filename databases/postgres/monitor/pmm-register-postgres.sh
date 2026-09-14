#!/bin/bash

echo "========================================================="
echo " Registering PostgreSQL instances in PMM"
echo "========================================================="
echo ""

# the prerun script starts together with pmm-agent: wait until it is connected
until pmm-admin status 2>/dev/null | grep -q "Connected *: true"; do
    echo "waiting for pmm-agent to connect..."
    sleep 2
done

# MONITOR_POSTGRES_HOSTS, _NAMES, _USERS and _PASSWORDS are comma separated
# lists in the same order: the Nth entry of each list belongs to the Nth host.
# An empty name falls back to the host; a missing user/password falls back to
# the first entry of its list.
field() {
    echo "$1" | cut -d, -f"$2"
}

i=1
for host in $(echo "${MONITOR_POSTGRES_HOSTS}" | tr ',' ' '); do
    name=$(field "${MONITOR_POSTGRES_NAMES}" "$i")
    user=$(field "${MONITOR_POSTGRES_USERS}" "$i")
    password=$(field "${MONITOR_POSTGRES_PASSWORDS}" "$i")

    [ -z "${name}" ] && name="${host}"
    [ -z "${user}" ] && user=$(field "${MONITOR_POSTGRES_USERS}" 1)
    [ -z "${password}" ] && password=$(field "${MONITOR_POSTGRES_PASSWORDS}" 1)
    i=$((i + 1))

    echo "[${name}] ${user}@${host}:5432"

    # host not in the project (its sub-stack is commented out) -> skip
    if ! getent hosts "${host}" >/dev/null 2>&1; then
        echo "[${name}] host ${host} not found, skipping"
        continue
    fi

    # wait for the database port (replaces depends_on, see compose.yaml)
    waited=0
    until timeout 5 bash -c "</dev/tcp/${host}/5432" 2>/dev/null; do
        if [ "${waited}" -ge "${MONITOR_WAIT_TIMEOUT:-300}" ]; then
            break
        fi
        echo "[${name}] waiting for the database to be reachable..."
        sleep 5
        waited=$((waited + 5))
    done
    if [ "${waited}" -ge "${MONITOR_WAIT_TIMEOUT:-300}" ]; then
        echo "[${name}] not reachable after ${waited}s, skipping"
        continue
    fi

    # drop any previous registration with this name (even from another node),
    # so restarts and changed credentials always end in a fresh registration
    pmm-admin remove postgresql "${name}" >/dev/null 2>&1

    pmm-admin add postgresql \
        --username="${user}" \
        --password="${password}" \
        --host="${host}" \
        --port=5432 \
        --query-source=pgstatmonitor \
        --service-name="${name}"
done
