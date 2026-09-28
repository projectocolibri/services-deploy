#!/bin/bash
# ============================================================================
# PMM Server entrypoint wrapper
#
# Purpose:       Enables or disables the Slack contact point from .env, then
#                starts PMM Server.
# Role:          Grafana has no setting to turn a contact point on or off:
#                - enabled:  the provisioning file is copied into Grafana's
#                            provisioning directory, which creates or updates
#                            the contact point on start
#                - disabled: the file is removed and, once Grafana is up, the
#                            contact point is deleted through Grafana's API.
#                            Deleting it through a provisioning file would stop
#                            Grafana from starting while a notification policy
#                            still uses it; the API refuses instead, so the
#                            contact point is kept and a warning is logged.
# Prerequisites: percona/pmm-server:3 image (provides /opt/entrypoint.sh and
#                curl). The Slack provisioning file mounted at SLACK_SOURCE.
#
# Variables:
#   ALERT_SLACK_ENABLED  (env) "true" installs the Slack contact point
#   SLACK_WEBHOOK_URL    (env) incoming webhook; required when enabled
#   PMM_ADMIN_PASSWORD   (env) Grafana admin password, for the API call
#   SLACK_SOURCE         (local) provisioning file mounted from the repository
#   SLACK_TARGET         (local) where Grafana reads alerting provisioning
#   GRAFANA_API          (local) Grafana's internal API base URL
#   remove_slack         (function) deletes the contact point once Grafana is up
#   "$@"                 (args) command passed to the image entrypoint
# ============================================================================

SLACK_SOURCE=/etc/pmm-alerting/slack.yaml
SLACK_TARGET=/usr/share/grafana/conf/provisioning/alerting/slack.yaml
GRAFANA_API=http://127.0.0.1:3000/graph/api

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
# Start PMM Server
# ----------------------------------------------------------------------------
# Hand over to the image entrypoint (becomes PID 1 through supervisord).
exec /opt/entrypoint.sh "$@"
