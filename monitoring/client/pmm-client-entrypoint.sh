#!/bin/bash

PMM_AGENT_SETUP_NODE_NAME="$(tr -d '[:space:]' < /host/etc/hostname)"
export PMM_AGENT_SETUP_NODE_NAME="${PMM_AGENT_SETUP_NODE_NAME:-$(hostname)}"

exec /usr/local/percona/pmm/bin/pmm-agent-entrypoint "$@"
