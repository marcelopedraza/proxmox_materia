#!/usr/bin/env bash
# helpers.sh – Shared helper functions for Proxmox course automation
# Source this file from create_student.sh and destroy_student.sh:
#   source "$(dirname "$0")/helpers.sh"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

# ---------------------------------------------------------------------------
# Configuration defaults (override via environment variables before sourcing)
# ---------------------------------------------------------------------------
: "${NUM_NODES:=1}"          # Number of Proxmox nodes in the cluster (currently single-node)
: "${NUM_STUDENTS:=40}"      # Total number of students
: "${VM_TEMPLATE_ID:=9000}"  # Proxmox template ID for the pfSense VM
: "${CT_TEMPLATE_ID:=8000}"  # Proxmox template ID for LXC containers
: "${BASE_VM_ID:=1000}"      # student VM ID = BASE_VM_ID + student_id
: "${BASE_CT_ID:=2000}"      # student CT IDs = BASE_CT_ID + student_id*10 + index
: "${NUM_CONTAINERS:=4}"     # LXC containers per student (ct0 … ct3)
: "${CT_STORAGE:=local-lvm}" # Storage pool used for containers
: "${VM_STORAGE:=local-lvm}" # Storage pool used for VM disks
: "${WAN_BRIDGE:=vmbr0}"     # Shared WAN bridge (all students share this)
: "${WAN_UPLINK_IFACE:=}"   # Physical uplink NIC for vmbr0 (e.g. "eno1") – must be set before setup_wan_bridge.sh
: "${NUM_LAN_NETWORKS:=3}"  # Number of isolated LAN bridges per student pool
: "${BASE_LAN_BRIDGE_ID:=100}" # LAN bridge name = vmbr(BASE_LAN_BRIDGE_ID + student_id*10 + net_index)

# Node names – adjust to match your actual Proxmox node hostnames
: "${NODES:=pve1}"

# ---------------------------------------------------------------------------
# Custom student role (StudentLab) – PVEVMUser baseline + snapshot management
# ---------------------------------------------------------------------------
: "${STUDENT_ROLE:=StudentLab}"
: "${STUDENT_ROLE_PRIVS:=VM.Config.CDROM,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.Monitor,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback}"

# Ensure the custom StudentLab role exists (idempotent, cluster-wide/global).
ensure_student_role() {
    if pveum role list --output-format json 2>/dev/null | grep -q "\"${STUDENT_ROLE}\""; then
        log_info "Role ${STUDENT_ROLE} already exists – skipping."
    else
        pveum role add "${STUDENT_ROLE}" -privs "${STUDENT_ROLE_PRIVS}"
        log_info "Role ${STUDENT_ROLE} created with privileges: ${STUDENT_ROLE_PRIVS}"
    fi
}

# ---------------------------------------------------------------------------
# Compute derived values for a given STUDENT_ID
# ---------------------------------------------------------------------------
# Returns the 0-based index of the node that should host this student.
get_node_index() {
    local student_id="$1"
    echo $(( student_id % NUM_NODES ))
}

# Returns the hostname of the target node for a student.
get_node_name() {
    local student_id="$1"
    local idx
    idx=$(get_node_index "$student_id")
    # Convert the space-separated NODES string to an array
    local nodes_arr
    read -r -a nodes_arr <<< "$NODES"
    echo "${nodes_arr[$idx]}"
}

# Returns the VM ID for a student's pfSense VM.
get_vm_id() {
    local student_id="$1"
    echo $(( BASE_VM_ID + student_id ))
}

# Returns the LXC container ID for a given student and container index (0-3).
get_ct_id() {
    local student_id="$1"
    local ct_index="$2"
    echo $(( BASE_CT_ID + student_id * 10 + ct_index ))
}

# Returns the per-student LAN bridge name for a given network index
# (0 .. NUM_LAN_NETWORKS-1).
get_lan_bridge() {
    local student_id="$1"
    local net_index="$2"
    # e.g. student 7, index 0 → vmbr170
    #      student 7, index 1 → vmbr171
    #      student 7, index 2 → vmbr172
    echo "vmbr$(( BASE_LAN_BRIDGE_ID + student_id * 10 + net_index ))"
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

# Validate that STUDENT_ID is a positive integer.
validate_student_id() {
    local student_id="$1"
    if ! [[ "$student_id" =~ ^[1-9][0-9]*$ ]]; then
        log_error "Invalid student ID '${student_id}'. Must be a positive integer."
        return 1
    fi
}

# Check whether a Proxmox VM/CT ID is already in use on this node.
# Returns 0 (true) if the ID is FREE, 1 if it is already taken.
vmid_is_free() {
    local vmid="$1"
    if qm status "$vmid" &>/dev/null || pct status "$vmid" &>/dev/null; then
        return 1  # already in use
    fi
    return 0  # free
}

# Verify that a template with the given ID exists (as a VM or CT).
template_exists() {
    local tmpl_id="$1"
    if qm config "$tmpl_id" &>/dev/null; then
        return 0
    fi
    if pct config "$tmpl_id" &>/dev/null; then
        return 0
    fi
    return 1
}
