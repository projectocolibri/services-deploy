#!/bin/sh

echo "========================================================="
echo " Registering MySQL instances in PMM"
echo "========================================================="
echo ""

# the prerun script starts together with pmm-agent: wait until it is connected
until pmm-admin status 2>/dev/null | grep -q "Connected *: true"; do
    echo "waiting for pmm-agent to connect..."
    sleep 2
done

# MONITOR_MYSQL_HOSTS, _NAMES, _USERS and _PASSWORDS are comma separated lists
# in the same order: the Nth entry of each list belongs to the Nth host.
# An empty name falls back to the host; a missing user/password falls back to
# the first entry of its list.
field() {
    echo "$1" | cut -d, -f"$2"
}

i=1
for host in $(echo "${MONITOR_MYSQL_HOSTS}" | tr ',' ' '); do
    name=$(field "${MONITOR_MYSQL_NAMES}" "$i")
    user=$(field "${MONITOR_MYSQL_USERS}" "$i")
    password=$(field "${MONITOR_MYSQL_PASSWORDS}" "$i")

    [ -z "${name}" ] && name="${host}"
    [ -z "${user}" ] && user=$(field "${MONITOR_MYSQL_USERS}" 1)
    [ -z "${password}" ] && password=$(field "${MONITOR_MYSQL_PASSWORDS}" 1)
    i=$((i + 1))

    echo "[${name}] ${user}@${host}:3306"

    # host not in the project (its sub-stack is commented out) -> skip
    if ! getent hosts "${host}" >/dev/null 2>&1; then
        echo "[${name}] host ${host} not found, skipping"
        continue
    fi

    # wait for the database (replaces depends_on, see compose.yaml)
    waited=0
    until MYSQL_PWD="${password}" mysqladmin ping --host="${host}" --user="${user}" --connect-timeout=5 >/dev/null 2>&1; do
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
    pmm-admin remove mysql "${name}" >/dev/null 2>&1

    pmm-admin add mysql \
        --username="${user}" \
        --password="${password}" \
        --host="${host}" \
        --port=3306 \
        --query-source=perfschema \
        --service-name="${name}"
done
