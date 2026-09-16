#!/bin/sh
# ============================================================================
# pgAdmin entrypoint wrapper
#
# Purpose:       Generates pgAdmin's server list (servers.json) from
#                environment variables, then starts pgAdmin.
# Role:          Lets the registered servers be configured in the stack's env
#                files instead of the UI. pgAdmin imports the file on start
#                (PGADMIN_REPLACE_SERVERS_ON_STARTUP).
# Prerequisites: dpage/pgadmin4 image (provides /entrypoint.sh). POSIX sh only.
#
# Variables:
#   ADMIN_HOSTS               (env) comma-separated hostnames to register
#   ADMIN_HOSTS_LABELS        (env) comma-separated display names, same order;
#                             a missing label falls back to the hostname
#   ADMIN_HOSTS_USER          (env) role name pre-filled for every server
#   PGADMIN_SERVER_JSON_FILE  (env) output path of the generated JSON
#   i                         (local) 1-based position of the current host,
#                             used as the JSON key and to pick its label
#   entries                   (local) accumulated JSON objects, one per host
#   host                      (local, loop) current hostname
#   label                     (local) display name of the current host
#   "$@"                      (args) command passed to the image entrypoint
# ============================================================================

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# field LIST N: prints the Nth item of a comma-separated list (empty if none).
#   $1  comma-separated list
#   $2  1-based position
field() {
    echo "$1" | cut -d, -f"$2"
}

# ----------------------------------------------------------------------------
# Build the server entries
# ----------------------------------------------------------------------------
# One JSON object per host, keyed by position, in group "Servers", port 5432,
# maintenance database "postgres" and SSL preferred.
i=1
entries=""
for host in $(echo "${ADMIN_HOSTS}" | tr ',' ' '); do
    label=$(field "${ADMIN_HOSTS_LABELS}" "$i")
    [ -z "${label}" ] && label="${host}"
    [ -n "${entries}" ] && entries="${entries},"
    entries="${entries}
    \"${i}\": {
      \"Name\": \"${label}\",
      \"Group\": \"Servers\",
      \"Host\": \"${host}\",
      \"Port\": 5432,
      \"MaintenanceDB\": \"postgres\",
      \"Username\": \"${ADMIN_HOSTS_USER}\",
      \"SSLMode\": \"prefer\"
    }"
    i=$((i + 1))
done

# ----------------------------------------------------------------------------
# Write servers.json
# ----------------------------------------------------------------------------
printf '{\n  "Servers": {%s\n  }\n}\n' "${entries}" > "${PGADMIN_SERVER_JSON_FILE}"

# ----------------------------------------------------------------------------
# Start pgAdmin
# ----------------------------------------------------------------------------
# Hand over to the image entrypoint (becomes PID 1).
exec /entrypoint.sh "$@"
