#!/bin/bash
set -e

if [ -f "${PGDATA}/standby.signal" ]; then
    echo "[primary] promoting: this data was a replica"
    rm -f "${PGDATA}/standby.signal"
fi

exec /entrypoint.sh "$@"
