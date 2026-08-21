#!/usr/bin/env bash
# destroy_student.sh – Remove a student's complete lab environment.
#
# Usage:
#   ./destroy_student.sh <student_id>
#
# Example:
#   ./destroy_student.sh 3
#
# WARNING: This script permanently deletes VMs, containers, the user account,
#          and the resource pool for the given student. It also removes the
#          per-student LAN bridge from the host. Use with care.
#
# Re-running is safe: each step checks for existence before attempting deletion.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "${SCRIPT_DIR}/helpers.sh"

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <student_id>"
    exit 1
fi

STUDENT_ID="$1"
validate_student_id "$STUDENT_ID" || exit 1

# ---------------------------------------------------------------------------
# Derived identifiers (same logic as create_student.sh)
# ---------------------------------------------------------------------------
STUDENT_NAME="student${STUDENT_ID}"
PVE_USER="${STUDENT_NAME}@pve"
POOL_NAME="${STUDENT_NAME}"
VM_ID=$(get_vm_id "$STUDENT_ID")

LAN_BRIDGES=()
for n in $(seq 0 $(( NUM_LAN_NETWORKS - 1 ))); do
    LAN_BRIDGES+=("$(get_lan_bridge "$STUDENT_ID" "$n")")
done

log_info "=== Destroying environment for ${STUDENT_NAME} ==="
log_info "  PVE user    : ${PVE_USER}"
log_info "  Pool        : ${POOL_NAME}"
log_info "  VM ID       : ${VM_ID}"
log_info "  LAN bridges : ${LAN_BRIDGES[*]}"

# ---------------------------------------------------------------------------
# Step 1 – Stop and delete LXC containers
# ---------------------------------------------------------------------------
log_info "--- Removing LXC containers ---"

for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
    CT_ID=$(get_ct_id "$STUDENT_ID" "$i")
    CT_NAME="${STUDENT_NAME}-ct${i}"

    if pct status "$CT_ID" &>/dev/null; then
        # Stop the container if it is running
        if pct status "$CT_ID" | grep -q "running"; then
            log_info "Stopping container ${CT_ID} (${CT_NAME})..."
            pct stop "$CT_ID"
        fi
        pct destroy "$CT_ID" --purge 1
        log_info "Container ${CT_ID} (${CT_NAME}) deleted."
    else
        log_info "Container ${CT_ID} does not exist – skipping."
    fi
done

# ---------------------------------------------------------------------------
# Step 2 – Stop and delete the pfSense VM
# ---------------------------------------------------------------------------
log_info "--- Removing pfSense VM ${VM_ID} ---"

if qm status "$VM_ID" &>/dev/null; then
    if qm status "$VM_ID" | grep -q "running"; then
        log_info "Stopping VM ${VM_ID}..."
        qm stop "$VM_ID"
        # Wait for the VM to fully stop (up to 30 s)
        for _ in $(seq 1 30); do
            qm status "$VM_ID" | grep -q "stopped" && break
            sleep 1
        done
        # Verify the VM actually stopped before destroying
        if ! qm status "$VM_ID" | grep -q "stopped"; then
            log_warn "VM ${VM_ID} did not stop cleanly after 30s; forcing destroy anyway."
        fi
    fi
    qm destroy "$VM_ID" --purge 1
    log_info "VM ${VM_ID} deleted."
else
    log_info "VM ${VM_ID} does not exist – skipping."
fi

# ---------------------------------------------------------------------------
# Step 3 – Remove ACL entries for the user
# ---------------------------------------------------------------------------
log_info "--- Removing ACL entries for ${PVE_USER} ---"
# pveum aclmod with an empty --roles string effectively removes the entry.
# We ignore errors in case the user or pool is already gone.
# Note: only the per-student ACL grant is revoked here. The StudentLab role
# itself is global/shared across all students and is never deleted.
pveum aclmod "/pool/${POOL_NAME}" \
    --users "${PVE_USER}" \
    --roles "${STUDENT_ROLE}" \
    --delete 1 2>/dev/null || true
log_info "ACL entries removed (if any)."

# ---------------------------------------------------------------------------
# Step 4 – Delete the Proxmox user
# ---------------------------------------------------------------------------
log_info "--- Removing user ${PVE_USER} ---"

if pveum user list --output-format json 2>/dev/null | grep -q "\"${PVE_USER}\""; then
    pveum user delete "${PVE_USER}"
    log_info "User ${PVE_USER} deleted."
else
    log_info "User ${PVE_USER} does not exist – skipping."
fi

# ---------------------------------------------------------------------------
# Step 5 – Delete the resource pool
# ---------------------------------------------------------------------------
log_info "--- Removing pool ${POOL_NAME} ---"

if pveum pool list --output-format json 2>/dev/null | grep -q "\"${POOL_NAME}\""; then
    pveum pool delete "${POOL_NAME}"
    log_info "Pool ${POOL_NAME} deleted."
else
    log_info "Pool ${POOL_NAME} does not exist – skipping."
fi

# ---------------------------------------------------------------------------
# Step 6 – Remove the LAN bridges
# ---------------------------------------------------------------------------
log_info "--- Removing ${NUM_LAN_NETWORKS} LAN bridges ---"

for LAN_BRIDGE in "${LAN_BRIDGES[@]}"; do
    if ip link show "${LAN_BRIDGE}" &>/dev/null; then
        ip link set "${LAN_BRIDGE}" down
        ip link delete "${LAN_BRIDGE}" type bridge
        log_info "Bridge ${LAN_BRIDGE} removed from the system."
    else
        log_info "Bridge ${LAN_BRIDGE} does not exist – skipping."
    fi

    # Remove the stanza from /etc/network/interfaces so the bridge is not
    # re-created on next boot.
    # The stanza is delimited by unique begin/end markers that include both the
    # student ID and bridge name, preventing accidental removal of other entries.
    BEGIN_MARKER="# BEGIN student${STUDENT_ID} ${LAN_BRIDGE}"
    END_MARKER="# END student${STUDENT_ID} ${LAN_BRIDGE}"

    if grep -qF "${BEGIN_MARKER}" /etc/network/interfaces; then
        sed -i "/^${BEGIN_MARKER}$/,/^${END_MARKER}$/d" /etc/network/interfaces
        # Remove blank lines that may have been left behind (consecutive empty lines only)
        sed -i '/^$/N;/^\n$/d' /etc/network/interfaces
        log_info "Bridge ${LAN_BRIDGE} removed from /etc/network/interfaces."
    fi
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_info "=== Environment for ${STUDENT_NAME} has been fully destroyed ==="
