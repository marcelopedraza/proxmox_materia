#!/usr/bin/env bash
# setup_wan_bridge.sh – Ensure the shared WAN bridge (vmbr0) exists on this
# node, bridged to the node's physical uplink NIC.
#
# Run this ONCE per Proxmox node, before any create_student.sh calls on that
# node. vmbr0 is shared cluster infrastructure used by every student's pool,
# so it is never torn down by destroy_student.sh — removal is manual only.
#
# Usage:
#   export WAN_UPLINK_IFACE=eno1   # must match the node's real uplink NIC
#   ./scripts/setup_wan_bridge.sh
#
# Re-running is safe: it checks for the bridge's existence before creating it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "${SCRIPT_DIR}/helpers.sh"

if [[ -z "${WAN_UPLINK_IFACE}" ]]; then
    log_error "WAN_UPLINK_IFACE is not set. Export it to the node's physical uplink NIC (e.g. eno1) before running this script."
    exit 1
fi

log_info "=== Setting up WAN bridge ${WAN_BRIDGE} (uplink: ${WAN_UPLINK_IFACE}) ==="

if ip link show "${WAN_BRIDGE}" &>/dev/null; then
    log_info "Bridge ${WAN_BRIDGE} already exists – skipping creation."
else
    ip link add name "${WAN_BRIDGE}" type bridge
    ip link set "${WAN_BRIDGE}" up
    log_info "Bridge ${WAN_BRIDGE} created and brought up."
fi

BEGIN_MARKER="# BEGIN wan bridge ${WAN_BRIDGE}"
if ! grep -qF "${BEGIN_MARKER}" /etc/network/interfaces; then
    cat >> /etc/network/interfaces <<EOF

# BEGIN wan bridge ${WAN_BRIDGE}
auto ${WAN_BRIDGE}
iface ${WAN_BRIDGE} inet manual
    bridge-ports ${WAN_UPLINK_IFACE}
    bridge-stp off
    bridge-fd 0
# END wan bridge ${WAN_BRIDGE}
EOF
    log_info "Bridge ${WAN_BRIDGE} added to /etc/network/interfaces."
fi

log_info "=== WAN bridge ${WAN_BRIDGE} is ready ==="
