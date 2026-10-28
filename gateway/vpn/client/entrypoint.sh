#!/bin/bash
# ============================================================================
# VPN client entrypoint
#
# Purpose:       Joins this server to the VPN host as a WireGuard peer, using
#                the host's network namespace.
# Role:          On start:
#                  1. builds the tunnel config from /config/peer.conf
#                  2. removes a leftover interface from an unclean stop
#                  3. refuses to start if a tunnel route overlaps a local route
#                     (e.g. both servers using the same NETWORK_SUBNET)
#                  4. brings the interface up with wg-quick
#                On stop (SIGTERM): takes the interface down, removing its
#                routes. Called with "health", runs the health check instead.
# Prerequisites: - network_mode: host and NET_ADMIN (compose.yaml)
#                - wg, wg-quick and ip (provided by the WireGuard image)
#                - WireGuard kernel module on the host
#
# Variables:
#   VPN_CLIENT_INTERFACE    (env) interface name on the host, 1-15 characters.
#                           Default: wg-services
#   VPN_CLIENT_KEEPALIVE    (env) PersistentKeepalive in seconds. Default: 25
#   VPN_CLIENT_ALLOWED_IPS  (env) comma-separated CIDRs replacing AllowedIPs
#                           from peer.conf. Default: empty (keep peer.conf's)
#   source_conf             (local) peer config copied from the VPN host
#   iface                   (local) resolved interface name
#   keepalive               (local) resolved keepalive interval
#   conf                    (local) generated config; its file name sets the
#                           interface name for wg-quick
#   allowed                 (local) AllowedIPs of the generated config
#   net                     (local, loop) one AllowedIPs network being checked
#   conflicts               (local) existing routes overlapping net
#   latest                  (local, health) time of the last handshake
#   "$1"                    (args) "health" runs the health check
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
source_conf=/config/peer.conf
iface="${VPN_CLIENT_INTERFACE:-wg-services}"
keepalive="${VPN_CLIENT_KEEPALIVE:-25}"
conf="/run/wireguard/${iface}.conf"

log() {
    echo "[vpn-client] $*"
}

# ----------------------------------------------------------------------------
# Health check mode
# ----------------------------------------------------------------------------
# Healthy when the interface exists and the last handshake is under 180 s old.
if [ "${1:-}" = "health" ]; then
    latest="$(wg show "${iface}" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)"
    [ -n "${latest}" ] && [ "${latest}" -gt 0 ] && [ $(( $(date +%s) - latest )) -lt 180 ]
    exit $?
fi

# ----------------------------------------------------------------------------
# Peer config
# ----------------------------------------------------------------------------
if [ ! -f "${source_conf}" ]; then
    log "${source_conf} not found."
    log "On the VPN host, add a name for this server to VPN_PEERS, then copy"
    log "gateway/vpn/host/config/peer_<name>/peer_<name>.conf to"
    log "gateway/vpn/client/config/peer.conf on this server."
    sleep 60
    exit 1
fi

# Build the tunnel config from peer.conf:
#   - DNS removed: would replace the host's resolver
#   - ListenPort removed: a random local port avoids clashes on the host
#   - PersistentKeepalive set: keeps the tunnel open through NAT
#   - AllowedIPs replaced when VPN_CLIENT_ALLOWED_IPS is set
mkdir -p "$(dirname "${conf}")"
umask 077
awk -v keepalive="${keepalive}" -v allowed="${VPN_CLIENT_ALLOWED_IPS:-}" '
    /^[[:space:]]*(DNS|ListenPort|PersistentKeepalive)[[:space:]]*=/ { next }
    allowed != "" && /^[[:space:]]*AllowedIPs[[:space:]]*=/ { print "AllowedIPs = " allowed; next }
    { print }
    /^[[:space:]]*\[Peer\]/ { print "PersistentKeepalive = " keepalive }
' "${source_conf}" > "${conf}"

# ----------------------------------------------------------------------------
# Leftover interface
# ----------------------------------------------------------------------------
# After a crash or kill the interface stays on the host; deleting it also
# removes its routes.
if ip link show "${iface}" >/dev/null 2>&1; then
    log "removing leftover interface ${iface}"
    ip link delete dev "${iface}"
fi

# ----------------------------------------------------------------------------
# Route conflict check
# ----------------------------------------------------------------------------
# A local route inside (root) or around (match, except the default route) a
# tunnel network would capture its traffic, e.g. a Docker network here using
# the VPN host's NETWORK_SUBNET.
allowed="$(awk -F= '/^[[:space:]]*AllowedIPs[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2 }' "${conf}" | tr ',' ' ')"
for net in ${allowed}; do
    case "${net}" in *:*) continue ;; esac
    conflicts="$( { ip -4 route show root "${net}"; ip -4 route show match "${net}" | grep -v '^default' || true; } | sort -u )"
    if [ -n "${conflicts}" ]; then
        log "route conflict for ${net}, which already routes locally:"
        echo "${conflicts}" | sed 's/^/[vpn-client]   /'
        log "use a different NETWORK_SUBNET on this server, or set VPN_CLIENT_ALLOWED_IPS"
        sleep 60
        exit 1
    fi
done

# ----------------------------------------------------------------------------
# Start the tunnel
# ----------------------------------------------------------------------------
stop() {
    log "stopping, taking ${iface} down"
    wg-quick down "${conf}" || ip link delete dev "${iface}" 2>/dev/null || true
    exit 0
}
trap stop TERM INT

log "bringing ${iface} up (AllowedIPs: ${allowed})"
wg-quick up "${conf}"
log "tunnel up"

# ----------------------------------------------------------------------------
# Supervise
# ----------------------------------------------------------------------------
# Exit (and let Docker restart the container) if the interface disappears.
while true; do
    sleep 30 &
    wait $!
    if ! ip link show "${iface}" >/dev/null 2>&1; then
        log "interface ${iface} disappeared, restarting"
        exit 1
    fi
done
