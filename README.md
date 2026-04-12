# proxmox_materia

Automated provisioning of isolated student lab environments on a Proxmox VE cluster.

---

## Overview

This repository automates the creation and teardown of per-student lab environments
for a course running on a 6-node Proxmox VE cluster with ~40 students.

Each student receives:
- A **Proxmox user** (`student<ID>@pve`) and **resource pool** (`student<ID>`)
- One **pfSense VM** cloned from template `9000` (ID `1000 + student_id`)
- Four **LXC containers** cloned from template `8000` (IDs `2000 + student_id * 10 + [0-3]`)
- A **dedicated LAN bridge** (`vmbr10<student_id>`) for isolation
- Role `PVEVMUser` scoped to their pool only

Students are distributed across nodes deterministically:

```
node_index = student_id % num_nodes
```

---

## Repository structure

```
.
├── inventory.ini          # 6 Proxmox nodes + connection settings
├── group_vars/
│   └── all.yml            # Configurable variables (IDs, storage, counts)
├── playbooks/
│   ├── deploy.yml         # Full deployment across the cluster
│   ├── destroy.yml        # Full teardown across the cluster
│   └── tasks/
│       └── user_and_pool.yml
├── roles/
│   ├── users/             # Create/delete Proxmox users
│   ├── pools/             # Create/delete resource pools + permissions
│   ├── networking/        # Create/delete per-student LAN bridges
│   ├── vms/               # Clone/destroy pfSense VMs
│   └── containers/        # Clone/destroy LXC containers
└── scripts/
    ├── helpers.sh          # Shared functions (logging, ID calculation)
    ├── create_student.sh   # Create one student environment (runs on node)
    └── destroy_student.sh  # Destroy one student environment (runs on node)
```

---

## Quick start

### Prerequisites

- Ansible ≥ 2.12 installed on the control machine
- SSH access to all 6 Proxmox nodes (root, key-based recommended)
- Proxmox templates present:
  - VM template ID `9000` (pfSense)
  - CT template ID `8000` (LXC base)

### 1. Configure inventory

Edit `inventory.ini` with your actual node hostnames/IPs:

```ini
[proxmox_nodes]
pve1 ansible_host=192.168.1.101 node_index=0
pve2 ansible_host=192.168.1.102 node_index=1
...
```

### 2. Adjust variables (optional)

Edit `group_vars/all.yml` to change the number of students, template IDs,
storage pools, etc.

### 3. Deploy all student environments

```bash
ansible-playbook -i inventory.ini playbooks/deploy.yml
```

Deploy a single student (e.g. student 7):

```bash
ansible-playbook -i inventory.ini playbooks/deploy.yml \
  -e "student_id_start=7 num_students=1"
```

### 4. Destroy all student environments

```bash
ansible-playbook -i inventory.ini playbooks/destroy.yml
```

Destroy a single student:

```bash
ansible-playbook -i inventory.ini playbooks/destroy.yml \
  -e "student_id_start=7 num_students=1"
```

---

## Bash scripts (direct node execution)

The scripts in `scripts/` run directly on a Proxmox node and are useful for
manual operations or testing without Ansible.

### Create one student

```bash
# Run on the target Proxmox node
./scripts/create_student.sh 3
```

### Destroy one student

```bash
# Run on the target Proxmox node
./scripts/destroy_student.sh 3
```

### Configuration via environment variables

Override defaults before calling the scripts:

```bash
export VM_TEMPLATE_ID=9000
export CT_TEMPLATE_ID=8000
export NUM_NODES=6
export NODES="pve1 pve2 pve3 pve4 pve5 pve6"
./scripts/create_student.sh 5
```

---

## Variables reference (`group_vars/all.yml`)

| Variable | Default | Description |
|---|---|---|
| `proxmox_nodes` | `[pve1..pve6]` | Ordered list of node hostnames |
| `num_nodes` | `6` | Number of cluster nodes |
| `num_students` | `40` | Total students to provision |
| `student_id_start` | `1` | First student ID |
| `vm_template_id` | `9000` | pfSense VM template ID |
| `ct_template_id` | `8000` | LXC container template ID |
| `base_vm_id` | `1000` | VM ID = base_vm_id + student_id |
| `base_ct_id` | `2000` | CT ID = base_ct_id + student_id * 10 + index |
| `num_containers` | `4` | Containers per student |
| `vm_storage` | `local-lvm` | Storage for VM disks |
| `ct_storage` | `local-lvm` | Storage for container rootfs |
| `wan_bridge` | `vmbr0` | Shared WAN bridge |
| `student_role` | `PVEVMUser` | Proxmox role granted to each student |

---

## Networking model

```
Internet
    │
  vmbr0 (WAN – shared by all students)
    │
 pfSense VM (student<N>-pfsense)
    │
 vmbr10<N> (LAN – per-student, isolated)
    ├── student<N>-ct0
    ├── student<N>-ct1
    ├── student<N>-ct2
    └── student<N>-ct3
```

---

## Notes

- Scripts are **idempotent**: re-running them for the same student ID is safe.
- Initial student password equals the username (e.g. `student3`). Students
  should change this on first login.
- Students cannot see each other's resources because each is scoped to their
  own resource pool with no cross-pool permissions.
- The teardown workflow (`destroy.yml` / `destroy_student.sh`) is designed to
  be fast for quick environment resets between course sessions.
