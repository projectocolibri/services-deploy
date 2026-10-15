#!/bin/bash
# ============================================================================
# PMM Server entrypoint wrapper
#
# Purpose:       Sets the web UI's HTTP port, enables or disables the Slack
#                contact point from .env and creates the custom alert rules,
#                then starts PMM Server.
# Role:          PMM has no setting for its HTTP port (fixed at 8080 in its
#                nginx config), so the listen line is rewritten on every start.
#                Grafana has no setting to turn a contact point on or off:
#                - enabled:  the provisioning file is copied into Grafana's
#                            provisioning directory, which creates or updates
#                            the contact point on start
#                - disabled: the file is removed and, once Grafana is up, the
#                            contact point is deleted through Grafana's API.
#                            Deleting it through a provisioning file would stop
#                            Grafana from starting while a notification policy
#                            still uses it; the API refuses instead, so the
#                            contact point is kept and a warning is logged.
#                Alert rules: once Grafana is up, each rule file in RULES_DIR
#                whose uid does not exist yet is created through Grafana's
#                API, in the folder "Custom alerts". Existing rules are left
#                as they are, so changes made in the UI are kept.
# Prerequisites: percona/pmm-server:3 image (provides /opt/entrypoint.sh,
#                curl and python3). The Slack provisioning file mounted at
#                SLACK_SOURCE, the rule files in RULES_DIR.
#
# Variables:
#   HTTP_PORT            (env) plain HTTP port of the web UI (PMM_HTTP_PORT)
#   NGINX_CONF           (local) PMM's nginx site config
#   ALERT_SLACK_ENABLED  (env) "true" installs the Slack contact point
#   SLACK_WEBHOOK_URL    (env) incoming webhook; required when enabled
#   PMM_ADMIN_PASSWORD   (env) Grafana admin password, for the API call
#   SLACK_SOURCE         (local) provisioning file mounted from the repository
#   SLACK_TARGET         (local) where Grafana reads alerting provisioning
#   GRAFANA_API          (local) Grafana's internal API base URL
#   RULES_DIR            (local) alert rule files (one Grafana alert rule per
#                        .json file, in the provisioning API format)
#   remove_slack         (function) deletes the contact point once Grafana is up
#   create_alert_rules   (function) creates the missing alert rules once
#                        Grafana is up
#   "$@"                 (args) command passed to the image entrypoint
# ============================================================================

NGINX_CONF=/etc/nginx/conf.d/pmm.conf
SLACK_SOURCE=/etc/pmm-alerting/slack.yaml
SLACK_TARGET=/usr/share/grafana/conf/provisioning/alerting/slack.yaml
GRAFANA_API=http://127.0.0.1:3000/graph/api
RULES_DIR=/etc/pmm-alerting/rules

log() {
    echo "[pmm-entrypoint] $*"
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
# remove_slack: waits up to 10 minutes for Grafana, then deletes the "slack"
# contact point (a no-op when it does not exist). Runs in the background.
remove_slack() {
    local i code
    for i in $(seq 1 120); do
        curl -sf "${GRAFANA_API}/health" >/dev/null 2>&1 && break
        sleep 5
    done
    code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
        -u "admin:${PMM_ADMIN_PASSWORD}" \
        "${GRAFANA_API}/v1/provisioning/contact-points/slack")
    case "${code}" in
        202) ;;
        409) log "WARNING: Slack is disabled but a notification policy still uses it, so it was kept. Remove it from the policy and restart pmm-server." ;;
        *) log "WARNING: could not remove the Slack contact point (HTTP ${code})" ;;
    esac
}

# create_alert_rules: waits up to 10 minutes for Grafana, then creates every
# rule in RULES_DIR whose uid does not exist yet, in the folder "Custom
# alerts" (created if missing). Existing rules are never changed, so edits
# made in the UI are kept; a rule deleted in the UI comes back on the next
# start (delete its file too). Rules are created without provenance, so they
# stay editable in the UI. Runs in the background.
create_alert_rules() {
    local i
    for i in $(seq 1 120); do
        curl -sf "${GRAFANA_API}/health" >/dev/null 2>&1 && break
        sleep 5
    done
    GRAFANA_API="${GRAFANA_API}" RULES_DIR="${RULES_DIR}" python3 - <<'EOF'
import base64, glob, json, os, urllib.error, urllib.request

api = os.environ['GRAFANA_API']
auth = 'Basic ' + base64.b64encode(('admin:' + os.environ['PMM_ADMIN_PASSWORD']).encode()).decode()
folder = {'uid': 'custom-alerts', 'title': 'Custom alerts'}


def call(method, path, body=None):
    """Grafana API call; returns the HTTP status."""
    req = urllib.request.Request(api + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': auth, 'Content-Type': 'application/json',
                                          'X-Disable-Provenance': 'true'})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status
    except urllib.error.HTTPError as e:
        if e.code >= 400 and e.code != 404:
            print(f'[pmm-entrypoint]   {method} {path}: HTTP {e.code} {e.read().decode()[:300]}')
        return e.code


if call('GET', f"/folders/{folder['uid']}") == 404:
    call('POST', '/folders', folder)

created = 0
for path in sorted(glob.glob(os.path.join(os.environ['RULES_DIR'], '*.json'))):
    try:
        rule = json.load(open(path, encoding='utf-8'))
        uid = rule['uid']
    except (ValueError, KeyError) as e:
        print(f'[pmm-entrypoint] WARNING: alert rule {os.path.basename(path)} skipped: {e}')
        continue
    if call('GET', f'/v1/provisioning/alert-rules/{uid}') != 404:
        continue
    rule.setdefault('folderUID', folder['uid'])
    rule.setdefault('orgID', 1)
    if call('POST', '/v1/provisioning/alert-rules', rule) == 201:
        created += 1
        print(f"[pmm-entrypoint] alert rule created: {rule.get('title', uid)}")
    else:
        print(f'[pmm-entrypoint] WARNING: alert rule {os.path.basename(path)} not created')
print(f'[pmm-entrypoint] alert rules: {created} created, the others already exist')
EOF
}

# ----------------------------------------------------------------------------
# HTTP port
# ----------------------------------------------------------------------------
# Replaces the plain HTTP listen line (8080 in the image, or the port of the
# previous start); the HTTPS line (listen 8443 ssl) is left alone.
if [ -n "${HTTP_PORT}" ]; then
    if grep -qE '^[[:space:]]*listen [0-9]+;' "${NGINX_CONF}"; then
        sed -i -E "s/^([[:space:]]*)listen [0-9]+;/\1listen ${HTTP_PORT};/" "${NGINX_CONF}"
        log "Web UI on HTTP port ${HTTP_PORT}"
    else
        log "WARNING: no HTTP listen line in ${NGINX_CONF}: HTTP_PORT ignored"
    fi
fi

# ----------------------------------------------------------------------------
# Slack contact point
# ----------------------------------------------------------------------------
if [ "${ALERT_SLACK_ENABLED}" = "true" ] && [ -z "${SLACK_WEBHOOK_URL}" ]; then
    log "WARNING: ALERT_SLACK_ENABLED=true but SLACK_WEBHOOK_URL is empty: Slack disabled"
    ALERT_SLACK_ENABLED=false
fi

if [ "${ALERT_SLACK_ENABLED}" = "true" ]; then
    log "Slack contact point enabled"
    cp "${SLACK_SOURCE}" "${SLACK_TARGET}"
else
    rm -f "${SLACK_TARGET}"
    remove_slack &
fi

# ----------------------------------------------------------------------------
# Stale PostgreSQL socket lock
# ----------------------------------------------------------------------------
# `docker restart` keeps the container's files, so PMM's internal PostgreSQL
# finds the socket lock files of its previous run (it listens in
# /run/postgresql and /tmp). When the PID written in them now belongs to
# another process of the new start, PostgreSQL refuses to start and Grafana
# with it. Nothing runs yet at this point, so they are stale.
rm -f /run/postgresql/.s.PGSQL.*.lock /tmp/.s.PGSQL.*.lock

# ----------------------------------------------------------------------------
# Custom alert rules
# ----------------------------------------------------------------------------
create_alert_rules &

# ----------------------------------------------------------------------------
# Start PMM Server
# ----------------------------------------------------------------------------
# Hand over to the image entrypoint (becomes PID 1 through supervisord).
exec /opt/entrypoint.sh "$@"
