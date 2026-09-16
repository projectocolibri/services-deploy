#!/bin/bash
# ============================================================================
# PMM service registration
#
# Purpose:       Registers this server's services in PMM Server.
# Role:          Runs as PMM_AGENT_PRERUN_SCRIPT on every pmm-client start:
#                  - always: this server's cAdvisor (external exporter)
#                  - when MONITOR_DATABASES=true: whichever of mysql-primary,
#                    mysql-replica, postgres-primary and postgres-replica are
#                    running on the network. Enable it on one server only.
#                Services that are not running are skipped; restart
#                pmm-client to register them later.
# Prerequisites: - pmm-agent starting in the same container (pmm-admin needs it)
#                - cAdvisor on localhost:8080 (shared network namespace)
#                - Monitoring accounts on the database primaries
#
# Variables:
#   node                       (local) PMM node name, from
#                              PMM_AGENT_SETUP_NODE_NAME (host's hostname)
#   PMM_AGENT_SETUP_NODE_NAME  (env) set by pmm-client-entrypoint.sh
#   MONITOR_DATABASES          (env) "true" registers the databases; any other
#                              value skips them
#   MONITOR_WAIT_TIMEOUT       (env, optional) seconds to wait for a port
#                              before skipping a service. Default: 300
#   MONITOR_MYSQL_USER         (env) MySQL monitoring account
#   MONITOR_MYSQL_PASSWORD     (env) password of MONITOR_MYSQL_USER
#   MONITOR_POSTGRES_USER      (env) PostgreSQL monitoring role
#   MONITOR_POSTGRES_PASSWORD  (env) password of MONITOR_POSTGRES_USER
#   waited                     (local, in wait_for) seconds waited so far
#   host                       (local, loop) database hostname being registered
# ============================================================================

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
node="${PMM_AGENT_SETUP_NODE_NAME}"

echo "========================================================="
echo " Registering services of node ${node} in PMM"
echo "========================================================="

# ----------------------------------------------------------------------------
# Wait for the agent
# ----------------------------------------------------------------------------
# The prerun script starts together with pmm-agent; pmm-admin only works once
# the agent is connected to PMM Server.
until pmm-admin status 2>/dev/null | grep -q "Connected *: true"; do
    echo "waiting for pmm-agent to connect..."
    sleep 2
done

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# wait_for HOST PORT: succeeds once PORT on HOST accepts TCP connections.
# Fails at once if HOST does not resolve (service not running), or after
# MONITOR_WAIT_TIMEOUT seconds (default 300) if the port never opens.
#   $1  hostname
#   $2  TCP port
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

# remove TYPE NAME: removes a service from PMM, ignoring "not found".
# PMM_AGENT_SETUP_FORCE re-creates this node on every start, but a service
# registered earlier from another node would still clash by name.
#   $1  service type (external, mysql, postgresql)
#   $2  service name
remove() {
    pmm-admin remove "$1" "$2" >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
# Container metrics (cAdvisor)
# ----------------------------------------------------------------------------
# Registered as an external exporter named cadvisor-<node>, group cadvisor.
if wait_for localhost 8080; then
    remove external "cadvisor-${node}"
    pmm-admin add external --service-name="cadvisor-${node}" \
        --listen-port=8080 --group=cadvisor
fi

# ----------------------------------------------------------------------------
# Database registration switch
# ----------------------------------------------------------------------------
if [ "${MONITOR_DATABASES}" != "true" ]; then
    echo "MONITOR_DATABASES=${MONITOR_DATABASES}: databases are registered by another server"
    exit 0
fi

# ----------------------------------------------------------------------------
# MySQL
# ----------------------------------------------------------------------------
# Query Analytics from performance_schema; both servers grouped in cluster
# "mysql".
for host in mysql-primary mysql-replica; do
    if wait_for "${host}" 3306; then
        remove mysql "${host}"
        pmm-admin add mysql --service-name="${host}" \
            --host="${host}" --port=3306 \
            --username="${MONITOR_MYSQL_USER}" --password="${MONITOR_MYSQL_PASSWORD}" \
            --query-source=perfschema --cluster=mysql
    fi
done

# ----------------------------------------------------------------------------
# PostgreSQL
# ----------------------------------------------------------------------------
# Query Analytics from pg_stat_monitor; both servers grouped in cluster
# "postgres".
for host in postgres-primary postgres-replica; do
    if wait_for "${host}" 5432; then
        remove postgresql "${host}"
        pmm-admin add postgresql --service-name="${host}" \
            --host="${host}" --port=5432 \
            --username="${MONITOR_POSTGRES_USER}" --password="${MONITOR_POSTGRES_PASSWORD}" \
            --query-source=pgstatmonitor --cluster=postgres
    fi
done
