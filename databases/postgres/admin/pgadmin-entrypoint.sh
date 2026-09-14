#!/bin/sh
# Builds pgAdmin's servers.json from ADMIN_HOSTS / ADMIN_HOSTS_LABELS
# (comma separated, same order), then starts pgAdmin.

field() {
    echo "$1" | cut -d, -f"$2"
}

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

printf '{\n  "Servers": {%s\n  }\n}\n' "${entries}" > "${PGADMIN_SERVER_JSON_FILE}"

exec /entrypoint.sh "$@"
