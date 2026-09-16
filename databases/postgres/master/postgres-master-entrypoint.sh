#!/bin/bash
# ============================================================================
# PostgreSQL primary entrypoint wrapper
#
# Purpose:       Starts PostgreSQL as the primary through the image's normal
#                entrypoint.
# Role:          Supports promotion: if this data directory used to belong to
#                a replica (the replica's volume was attached to the primary
#                service), removing standby.signal makes PostgreSQL end
#                recovery and start accepting writes.
# Prerequisites: Percona Distribution for PostgreSQL image (provides
#                /entrypoint.sh and sets PGDATA).
#
# Variables:
#   PGDATA  (env, set by the image) data directory, /data/db
#   "$@"    (args) command from compose.yaml (postgres and -c settings)
# ============================================================================

# ----------------------------------------------------------------------------
# Shell options
# ----------------------------------------------------------------------------
# Exit on the first failing command.
set -e

# ----------------------------------------------------------------------------
# Promotion
# ----------------------------------------------------------------------------
# standby.signal marks a data directory as a standby; without it PostgreSQL
# starts as a primary.
if [ -f "${PGDATA}/standby.signal" ]; then
    echo "[primary] promoting: this data was a replica"
    rm -f "${PGDATA}/standby.signal"
fi

# ----------------------------------------------------------------------------
# Start PostgreSQL
# ----------------------------------------------------------------------------
# Hand over to the image entrypoint (becomes PID 1).
exec /entrypoint.sh "$@"
