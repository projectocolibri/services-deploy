#!/bin/bash
# ============================================================================
# PMM client entrypoint wrapper
#
# Purpose:       Names this PMM node after the host's hostname, then starts
#                pmm-agent through the image's entrypoint.
# Role:          Gives every server a unique, recognizable node name in PMM
#                without per-server configuration.
# Prerequisites: - percona/pmm-client image
#                - Host's /etc/hostname mounted at /host/etc/hostname
#
# Variables:
#   PMM_AGENT_SETUP_NODE_NAME  (env, exported) node name used when the agent
#                              registers. Value: the host's hostname with
#                              whitespace removed; falls back to the
#                              container's hostname if the file is empty
#   "$@"                       (args) passed through to pmm-agent-entrypoint
# ============================================================================

# ----------------------------------------------------------------------------
# Node name
# ----------------------------------------------------------------------------
PMM_AGENT_SETUP_NODE_NAME="$(tr -d '[:space:]' < /host/etc/hostname)"
export PMM_AGENT_SETUP_NODE_NAME="${PMM_AGENT_SETUP_NODE_NAME:-$(hostname)}"

# ----------------------------------------------------------------------------
# Start pmm-agent
# ----------------------------------------------------------------------------
# Hand over to the image entrypoint (becomes PID 1).
exec /usr/local/percona/pmm/bin/pmm-agent-entrypoint "$@"
