# Plan: Student snapshot permission, 3 networks per pool, WAN bridge

## Context

The current provisioning scaffold (Ansible roles + bash scripts) grants each
student the built-in `PVEVMUser` role on their pool and creates exactly one
LAN bridge per student (`vmbr10<id>`), wired to pfSense's `net1` and to every
container's `net0`. `vmbr0` ("WAN bridge") is referenced everywhere as the
shared internet-facing bridge but is never actually created by any role or
script — it's assumed to pre-exist on each node, which it currently doesn't.

Three changes are needed:
1. Students need permission to manage their own VM/CT snapshots (create,
   rollback, delete) — not available on the stock `PVEVMUser` role.
2. Each student pool needs 3 isolated virtual networks instead of 1, so
   students can build multi-segment lab topologies. Per your direction,
   provisioning only creates the 3 bridges — it does **not** auto-wire them
   to pfSense or the containers; students configure that wiring themselves
   in Proxmox/pfSense (they already get `VM.Config.Network` via their role).
3. `vmbr0` must actually be created (once per node, bridged to each node's
   physical uplink NIC) so pools have real internet connectivity, since
   nothing currently provisions it.

## 1. Snapshot permissions — custom role

`PVEVMUser` is a built-in role and can't be edited, so add a custom role that
carries the same baseline privileges plus snapshot management.

- `group_vars/all.yml`: replace `student_role: PVEVMUser` with:
  ```yaml
  student_role: StudentLab
  student_role_privileges:
    - VM.Config.CDROM
    - VM.Config.Cloudinit
    - VM.Config.Disk
    - VM.Config.HWType
    - VM.Config.Memory
    - VM.Config.Network
    - VM.Config.Options
    - VM.Console
    - VM.Monitor
    - VM.PowerMgmt
    - VM.Snapshot
    - VM.Snapshot.Rollback
  ```
- `roles/pools/tasks/main.yml`: before the existing `pveum aclmod` grant
  (`roles/pools/tasks/main.yml:33-40`), add an idempotent "ensure role
  exists" step: check `pveum role list --output-format json` for
  `student_role`, and if missing, `pveum role add {{ student_role }} -privs
  "{{ student_role_privileges | join(',') }}"`. The role is global/shared —
  it is never deleted on student teardown, only the per-student ACL grant is
  revoked (existing `roles/pools/tasks/main.yml:43-52` logic, unchanged
  except it now revokes `StudentLab` instead of `PVEVMUser`).
- `scripts/helpers.sh`: add `STUDENT_ROLE="StudentLab"` and
  `STUDENT_ROLE_PRIVS="..."` defaults, plus a new `ensure_student_role()`
  function replicating the check-then-`pveum role add` logic.
- `scripts/create_student.sh:98-104`: call `ensure_student_role` first, then
  replace the hardcoded `--roles PVEVMUser` with `--roles "${STUDENT_ROLE}"`.

## 2. Three virtual networks per pool

Extend the existing LAN-bridge formula to a per-index variant, following the
same style as the CT ID formula (`base_ct_id + student_id*10 + index`).

- `group_vars/all.yml`: add `num_lan_networks: 3` and `base_lan_bridge_id:
  100`. Bridge name becomes `vmbr{{ base_lan_bridge_id + student_id*10 +
  net_index }}` (e.g. student 7 → `vmbr170`, `vmbr171`, `vmbr172`).
- `roles/networking/tasks/main.yml`: wrap the existing create/destroy logic
  (currently single-bridge, `roles/networking/tasks/main.yml:10-62`) in a
  loop over `range(0, num_lan_networks)`, computing each bridge name per
  iteration. Same `ip link add ... type bridge` + `/etc/network/interfaces`
  `blockinfile` persistence pattern as today, just repeated 3x with distinct
  markers per bridge.
- `scripts/helpers.sh`: replace the single `get_lan_bridge(student_id)` with
  `get_lan_bridge(student_id, net_index)` using the same formula; add
  `NUM_LAN_NETWORKS=3` and `BASE_LAN_BRIDGE_ID=100` config defaults.
- `scripts/create_student.sh`: loop the LAN bridge creation step 3x instead
  of once.
- `scripts/destroy_student.sh`: loop the marker-based
  `/etc/network/interfaces` cleanup 3x (one pass per bridge) instead of once.
- **No auto-wiring**: remove the current automatic LAN attachment in
  `roles/vms/tasks/main.yml:39-48` (pfSense keeps `net0=wan_bridge` only at
  creation time) and in `roles/containers/tasks/create_container.yml:28-34`
  (containers are created without a pre-wired `net0`). Students attach
  pfSense's `net1`/`net2`/`net3` and each container's `net0` to whichever of
  the 3 pool bridges they choose, using the `VM.Config.Network` privilege
  their role already grants.

## 3. WAN bridge (vmbr0) creation

Add a small, separate role that runs once per node (not per student) to
ensure `vmbr0` exists, bridged to the node's physical uplink NIC.

- `group_vars/all.yml`: add `wan_uplink_interface: ""` — placeholder,
  **you'll need to fill this in** with the actual NIC name (e.g. `eno1`)
  before running deploy, since it's the same across all 6 nodes per your
  answer.
- New `roles/wan/tasks/main.yml`: idempotent (`creates:
  /sys/class/net/vmbr0` guard) `ip link add name vmbr0 type bridge` +
  `ip link set vmbr0 up`, then persist via the same `blockinfile` →
  `/etc/network/interfaces` pattern used in `roles/networking`, with
  `bridge-ports {{ wan_uplink_interface }}`.
- `playbooks/deploy.yml`: include the `wan` role once per node at the top of
  Play 2 (the `proxmox_nodes`-group play), before the per-student
  networking/vms/containers loop.
- Not added to `playbooks/destroy.yml` — `vmbr0` is shared cluster
  infrastructure used by every student's pool, so student teardown must not
  remove it. Document this as manual-only teardown.
- `scripts/helpers.sh` / new `scripts/setup_wan_bridge.sh`: bash-path
  equivalent, run once per node before any `create_student.sh` calls. Reads
  `WAN_UPLINK_IFACE` from `helpers.sh` (empty by default, must be filled in).

## Other files to update

- `README.md`: document the custom `StudentLab` role and its privileges, the
  3-networks-per-pool scheme (and that wiring is manual/student-driven), and
  the one-time `vmbr0` setup step (`roles/wan` in Ansible,
  `scripts/setup_wan_bridge.sh` in bash), including the need to set
  `wan_uplink_interface` / `WAN_UPLINK_IFACE` before first run.

## Verification

No live Proxmox cluster is available in this environment, so validation is
static plus a documented manual check:

- `ansible-playbook playbooks/deploy.yml --syntax-check` and
  `ansible-playbook playbooks/destroy.yml --syntax-check`
- `bash -n scripts/create_student.sh scripts/destroy_student.sh
  scripts/helpers.sh scripts/setup_wan_bridge.sh`
- Manual check on a real node after applying: `pveum role list` (confirm
  `StudentLab` with snapshot privs), `pveum acl list /pool/student<id>`
  (confirm role grant), `ip link show | grep vmbr` (confirm `vmbr0` +
  3 per-student bridges), `cat /etc/network/interfaces` (confirm persisted
  stanzas survive reboot).
