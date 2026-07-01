#!/usr/bin/env bash
# create_student.sh – Create a full isolated lab environment for one student.
#
# Usage:
#   ./create_student.sh <student_id>
#
# Example:
#   ./create_student.sh 3
#
# This script must be run directly on a Proxmox node (or via SSH).
# It uses the Proxmox CLI tools: qm, pct, pveum.
#
# Re-running the script for the same student is safe: each step checks
# whether the resource already exists before trying to create it.

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
# Derived identifiers
# ---------------------------------------------------------------------------
STUDENT_NAME="student${STUDENT_ID}"           # e.g. student3
PVE_USER="${STUDENT_NAME}@pve"                 # e.g. student3@pve
POOL_NAME="${STUDENT_NAME}"                    # resource pool name
VM_ID=$(get_vm_id "$STUDENT_ID")               # e.g. 1003
VM_NAME="${STUDENT_NAME}-pfsense"              # e.g. student3-pfsense
LAN_BRIDGE=$(get_lan_bridge "$STUDENT_ID")     # e.g. vmbr103

log_info "=== Creating environment for ${STUDENT_NAME} ==="
log_info "  PVE user   : ${PVE_USER}"
log_info "  Pool       : ${POOL_NAME}"
log_info "  VM ID      : ${VM_ID}  (${VM_NAME})"
log_info "  LAN bridge : ${LAN_BRIDGE}"

# ---------------------------------------------------------------------------
# Step 1 – Validate templates exist
# ---------------------------------------------------------------------------
log_info "--- Validating templates ---"

if ! template_exists "$VM_TEMPLATE_ID"; then
    log_error "VM template ${VM_TEMPLATE_ID} not found. Aborting."
    exit 1
fi

if ! template_exists "$CT_TEMPLATE_ID"; then
    log_error "CT template ${CT_TEMPLATE_ID} not found. Aborting."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2 – Create resource pool
# ---------------------------------------------------------------------------
log_info "--- Creating resource pool ${POOL_NAME} ---"

if pveum pool list --output-format json 2>/dev/null | grep -q "\"${POOL_NAME}\""; then
    log_info "Pool ${POOL_NAME} already exists – skipping."
else
    pveum pool add "${POOL_NAME}" --comment "Lab pool for ${STUDENT_NAME}"
    log_info "Pool ${POOL_NAME} created."
fi

# ---------------------------------------------------------------------------
# Step 3 – Create Proxmox user
# ---------------------------------------------------------------------------
log_info "--- Creating user ${PVE_USER} ---"

if pveum user list --output-format json 2>/dev/null | grep -q "\"${PVE_USER}\""; then
    log_info "User ${PVE_USER} already exists – skipping."
else
    # Initial password equals the username as per the course spec.
    # NOTE: This is intentional for a teaching environment – instructors must
    # remind students to change their password on first login.
    # To generate random passwords instead, replace "${STUDENT_NAME}" with:
    #   $(openssl rand -base64 12)
    # and write the credentials to a CSV file for distribution.
    pveum user add "${PVE_USER}" \
        --password "${STUDENT_NAME}" \
        --comment "Student ${STUDENT_ID} lab account" \
        --groups ""
    log_info "User ${PVE_USER} created."
fi

# ---------------------------------------------------------------------------
# Step 4 – Assign permissions: PVEVMUser on the student pool
# ---------------------------------------------------------------------------
log_info "--- Assigning permissions ---"
pveum aclmod "/pool/${POOL_NAME}" \
    --users "${PVE_USER}" \
    --roles PVEVMUser
log_info "Permissions set: ${PVE_USER} → PVEVMUser on /pool/${POOL_NAME}"

# ---------------------------------------------------------------------------
# Step 5 – Create per-student LAN bridge (idempotent via ip link check)
# ---------------------------------------------------------------------------
log_info "--- Creating LAN bridge ${LAN_BRIDGE} ---"

if ip link show "${LAN_BRIDGE}" &>/dev/null; then
    log_info "Bridge ${LAN_BRIDGE} already exists – skipping creation."
else
    # Create the bridge interface and bring it up
    ip link add name "${LAN_BRIDGE}" type bridge
    ip link set "${LAN_BRIDGE}" up
    log_info "Bridge ${LAN_BRIDGE} created and brought up."
fi

# Make bridge persistent by appending to /etc/network/interfaces if not present.
# We use unique begin/end markers (including both student ID and bridge name)
# so the block can be reliably identified and removed later by destroy_student.sh.
BEGIN_MARKER="# BEGIN student${STUDENT_ID} ${LAN_BRIDGE}"
if ! grep -qF "${BEGIN_MARKER}" /etc/network/interfaces; then
    cat >> /etc/network/interfaces <<EOF

# BEGIN student${STUDENT_ID} ${LAN_BRIDGE}
auto ${LAN_BRIDGE}
iface ${LAN_BRIDGE} inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
# END student${STUDENT_ID} ${LAN_BRIDGE}
EOF
    log_info "Bridge ${LAN_BRIDGE} added to /etc/network/interfaces."
fi

# ---------------------------------------------------------------------------
# Step 6 – Clone pfSense VM from template
# ---------------------------------------------------------------------------
log_info "--- Cloning pfSense VM (template ${VM_TEMPLATE_ID} → ID ${VM_ID}) ---"

if ! vmid_is_free "$VM_ID"; then
    log_info "VM ${VM_ID} already exists – skipping clone."
else
    qm clone "${VM_TEMPLATE_ID}" "${VM_ID}" \
        --name "${VM_NAME}" \
        --full 1 \
        --storage "${VM_STORAGE}"

    # Configure network interfaces:
    #   net0 = WAN  → shared bridge vmbr0
    #   net1 = LAN  → per-student bridge
    qm set "${VM_ID}" \
        --net0 virtio,bridge="${WAN_BRIDGE}" \
        --net1 virtio,bridge="${LAN_BRIDGE}"

    # Add the VM to the student's resource pool
    qm set "${VM_ID}" --pool "${POOL_NAME}"

    log_info "VM ${VM_ID} (${VM_NAME}) created and added to pool ${POOL_NAME}."
fi

# ---------------------------------------------------------------------------
# Step 7 – Clone LXC containers from template
# ---------------------------------------------------------------------------
log_info "--- Cloning ${NUM_CONTAINERS} LXC containers ---"

for i in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
    CT_ID=$(get_ct_id "$STUDENT_ID" "$i")
    CT_NAME="${STUDENT_NAME}-ct${i}"

    if ! vmid_is_free "$CT_ID"; then
        log_info "Container ${CT_ID} (${CT_NAME}) already exists – skipping."
        continue
    fi

    pct clone "${CT_TEMPLATE_ID}" "${CT_ID}" \
        --hostname "${CT_NAME}" \
        --storage "${CT_STORAGE}" \
        --full 1

    # Connect the container to the student LAN bridge
    pct set "${CT_ID}" \
        --net0 name=eth0,bridge="${LAN_BRIDGE}",ip=dhcp

    # Add the container to the student's resource pool
    pveum pool modify "${POOL_NAME}" --vms "${CT_ID}"

    log_info "Container ${CT_ID} (${CT_NAME}) created and added to pool ${POOL_NAME}."
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_info "=== Environment for ${STUDENT_NAME} is ready ==="
log_info "  Login : ${PVE_USER}"
log_info "  Pass  : ${STUDENT_NAME}  (initial – student should change this)"
