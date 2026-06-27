**An interactive Bash tool for managing LXC containers across a Proxmox VE cluster — renumber, migrate, change hostname/VLAN/IP, and verify cluster consistency from any node.**

<img width="813" height="526" alt="Screenshot2026-06-27 at 13 41 37" src="https://github.com/user-attachments/assets/54fd9b2a-b632-4130-a36a-46d362548dad" />

## Why this exists

Proxmox VE's `pct` CLI is powerful but rigid. Renumbering a container means stopping it, renaming its LVM volume, editing the cluster-synced config, and remembering to update backup jobs — all without a single command that does it safely. Migrating a container with `nesting=1` regularly races the kernel's mount teardown, leaving the source LV held open and the destination filesystem appearing "corrupted." When something goes wrong mid-operation, you end up with ghost containers: running processes with no config, LVs that won't `lvremove`, and a cluster state that disagrees with reality.

This script handles the entire workflow interactively from any node in the cluster — with pre-flight consistency checks, hostname/VLAN/IP edits, nesting-aware migration timing, post-rename verification, and rollback snippets for every mutation.

## What it does

- **Cluster-aware operation** — discovers all nodes via `pvesh`, displays CT/VM counts and free resources, routes commands to the node that owns the CT via SSH
- **Unified configure flow** — change container ID, hostname, VLAN tag, IP address, and/or target node in one operation; Enter at any prompt to keep the current value
- **Safe renumbering** — stops the CT, renames the LVM volume on the owning node, updates the cluster-synced config, optionally updates backup jobs, and writes a rollback snippet
- **Nesting-aware migration** — detects `nesting=1` / `fuse` features, explicitly stops the CT, waits 10 seconds for kernel mount namespaces to release, then polls the LV's `lv_attr` open flag before migrating — avoiding the `lvremove ... filesystem in use` race that plagues `pct migrate --restart`
- **Pre-flight consistency checks** — on startup, scans every node for orphan LVs (no config references), misplaced LVs (LV on node X but config on node Y), and orphan `/var/lib/lxc/<id>/` directories; pauses for acknowledgement on issues
- **Post-rename verification** — mounts the renamed LV read-only and confirms `/etc/hostname` inside matches the PVE config; surfaces mismatches before the CT starts
- **Post-migration cleanup** — verifies the source-side LV is gone after `pct migrate`; force-removes if PVE's own cleanup failed (which it does for nesting CTs); removes leftover `/var/lib/lxc/<id>/` on the source
- **Egress IP diagnostic** — queries each online node's outbound public IP via curl/wget/dig fallback chain; flags split-routing when nodes egress through different WAN IPs
- **Rollback snippets** — every renumber, hostname change, and network change generates a bash script under `/var/log/pct-renumber-rollback/` that reverses the operation
- **Dry-run mode** — preview every command without executing
- **No external dependencies** — pure Bash + tools already installed on every PVE node


## Quick start

```bash
git clone https://github.com/njordium/pve-ct-manager.git
cd pve-ct-manager
chmod +x pct-renumber.sh
sudo ./pct-renumber.sh
```

Run from any node in the cluster. The script routes operations to the node that owns the container via SSH using the PVE-managed root keys at `/etc/pve/priv/authorized_keys`.

## Requirements

| Requirement | Details |
| --- | --- |
| OS | Proxmox VE 8.x or 9.x |
| Privileges | Root on a PVE cluster node |
| Tools | `pct`, `pvesh`, `lvs`, `lvrename`, `ssh` (all standard on PVE) |
| Storage | LVM-thin (`local-lvm`) — other backends untested |
| Cluster | Multi-node cluster recommended; single-node operation works for non-migration actions |

## Usage

```
Usage: ./pct-renumber.sh [--dry-run] [--color|--no-color]

Options:
  --dry-run    Show what would be done without making any changes
  --color      Enable ANSI colour output (default)
  --no-color   Disable ANSI colour output (useful for terminals with broken SGR)
  -h, --help   Show this help

Rollback snippets: /var/log/pct-renumber-rollback
Logs:             /var/log/pct-renumber.log
```

### Interactive menu

The script presents this menu after the startup consistency check:

```
  ━━━ Cluster: Rivendell ━━━

  Node         Status     CTs     VMs     Free RAM     Free Disk
  ----         ------     ---     ---     --------     ---------
  aiwendil     ● online   [27]    [0]     75 GB        562 GB
  alatar       ● online   [1]     [0]     29 GB        345 GB
  curumo       ● online   [20]    [1]     23 GB        138 GB

  What would you like to do?

  1) Configure a container           — change ID, hostname, VLAN, IP, and/or node
  2) Refresh cluster overview        — re-poll cluster state
  3) Show egress public IPs          — check WAN IP per node
  q) Quit
```

### Typical workflow

1. Run the script — startup automatically discovers the cluster and runs a consistency check
2. **1** — Configure a container; select a node, pick the CT, and answer the prompts
3. Review the operation summary; confirm with `y`
4. Watch the explicit stop → settle → migrate → rename → verify steps
5. When prompted, decide whether to start the CT on the target node


### Configure flow

After selecting a container, the script prompts for each attribute in sequence — press Enter to keep the current value:

```
━━━ Source Container Details ━━━
  ID:             22512
  Hostname:       nginxpmtxt
  Node:           aiwendil
  Status:         running
  VLAN tag:       225
  IP:             10.46.225.13/24
  Memory:         2048 MB
  Disk size:      8G

[→] Press Enter at any prompt to keep the current value.

New hostname (Enter to keep 'nginxpmtxt'):
New VLAN tag (Enter to keep '225', '-' to remove):
New IP CIDR (Enter to keep '10.46.225.13/24', 'dhcp' for DHCP):

  Suggested ID based on VLAN+IP: 22513
New container ID (Enter to keep 22512): 22513

  Available target nodes:
  1) aiwendil      free: 75 GB RAM, 562 GB disk (current)
  2) alatar        free: 29 GB RAM, 348 GB disk
  3) curumo        free: 23 GB RAM, 138 GB disk

Target node (Enter to keep aiwendil): 2
```

The operation summary then shows exactly what will change — only the attributes you modified are listed. If nothing changed, the script returns to the menu without doing anything.

---

## How it works

### Cluster discovery

A single `pvesh get /cluster/resources --output-format yaml` call returns nodes, containers, VMs, and storage in one query. The script parses the YAML in pure awk (no jq dependency) and builds in-memory maps of CT counts, VM counts, free RAM, free disk, and a node→IP map sourced from `/etc/pve/.members`. The IP map is what makes cross-node SSH reliable even when `/etc/hosts` or DNS is stale — PVE's authoritative node IPs always work.

### Command routing

Every `pct` command runs on the node that owns the container. `pct stop`, `pct status`, and `pct migrate` execute on the source node; `lvrename`, post-migration `pct` calls, and `/var/lib/lxc/` cleanup execute on the target node. A single `ssh_prefix()` helper produces consistent SSH options (`BatchMode=yes`, `ConnectTimeout=5`, `StrictHostKeyChecking=accept-new`) for every remote invocation.

### Nesting-aware migration

PVE's `pct migrate --restart` races the kernel for containers with `features: nesting=1`. The `pct shutdown` reports complete before lxcfs and mount-propagation hooks finish releasing the rootfs; the migration's `dd` then captures an inconsistent filesystem state, and the source-side `lvremove` fails with "filesystem in use." This script avoids the race entirely:

```
[→] Stopping CT 22514 on aiwendil...
[→] CT has nesting/fuse features — waiting 10s for kernel mount teardown...
[→] Migrating CT 22514 from aiwendil to alatar...
...
[→] Verifying source-side cleanup on aiwendil...
[✓] Source LV removed cleanly.
```

1. Explicit `pct stop` and wait for `pct status` to report `stopped`
2. 10-second sleep for nesting/fuse CTs (2 seconds otherwise) to let kernel mount namespaces release
3. Poll the LV's `lv_attr` open flag for up to 15 additional seconds
4. Plain `pct migrate` (no `--restart`) — clean offline migration
5. Post-migration verification polls the source LV; if it persists, force-deactivates and removes it

### Pre-flight consistency check

On startup the script scans every online node for:

- **Orphan LVs** — `vm-NNNNN-disk-N` volumes where no `/etc/pve/nodes/*/lxc/NNNNN.conf` references the CT ID
- **Misplaced LVs** — LV exists on node X but the CT config lives on node Y (indicates a half-completed migration)
- **Orphan directories** — `/var/lib/lxc/<id>/` with no matching config on the node

Issues are warned, not auto-cleaned. The script pauses for acknowledgement when problems are found, giving the operator a chance to investigate before proceeding.

### Post-rename verification

After every renumber, the script mounts the renamed LV read-only on the target node, reads `/etc/hostname` from inside, and compares it to the `hostname:` line in the PVE config. A mismatch indicates that the wrong LV was renamed — catching the failure mode where prior orphans cause the rename target to be the wrong volume.

### Rollback snippets

Every mutation writes a bash script to `/var/log/pct-renumber-rollback/` containing the reverse operations. The script header documents which node to run it on (for cross-node migrations). Snippets are self-contained and idempotent where possible.

---

## Diagnostics

### Egress public IP per node

Menu option **3** queries each online node's outbound WAN IP using a fallback chain of curl → wget → dig. Useful for verifying NAT consistency across the cluster and spotting nodes that route through a different WAN (e.g. a WireGuard exit VLAN).

```
━━━ Egress Public IP per Node ━━━

[→] Querying each node's outbound WAN IP (5s timeout each)...

  Node         Public IP          Egress IF    Service / note
  ----         ---------          ---------    ------------
  aiwendil     79.136.21.142      vmbr0        curl ifconfig.me
  alatar       79.136.21.142      vmbr0        curl ifconfig.me
  curumo       79.136.21.142      vmbr0        curl ifconfig.me

[✓] All online nodes share the same egress public IP.
```

### Dry-run mode

```bash
sudo ./pct-renumber.sh --dry-run
```

Every mutation is replaced with a `[! DRY]` line showing the command that would have run. Configuration changes show old and new values without writing.

---

## Troubleshooting

**`Configuration file 'nodes/<thishost>/lxc/<id>.conf' does not exist`**

You're running on a node that doesn't own the container. This script handles routing automatically — make sure you're using the version with `ssh_prefix()` (1.0.0 or later). If you see this error, the SSH key exchange between nodes may be incomplete; check `/etc/pve/priv/authorized_keys`.

**`Logical volume pve/vm-<id>-disk-0 contains a filesystem in use`** after migration

The CT's `nesting=1` raced the kernel mount teardown. The script's settle wait should prevent this — if it still occurs, increase the sleep in the `HAS_COMPLEX_FEATURES` branch. As a manual recovery:

```bash
ssh root@<src-node> "lvchange -an -f pve/vm-<id>-disk-0 && lvremove -f pve/vm-<id>-disk-0"
```

**Pre-flight reports orphan LV but `lvremove` fails**

The LV is still held by a kernel mount namespace from a previous session. Sniff what's inside before removing:

```bash
ssh root@<node> "mkdir -p /mnt/sniff && mount -o ro /dev/pve/vm-<id>-disk-0 /mnt/sniff && cat /mnt/sniff/etc/hostname"
```

If it's a real CT that lost its config, restore the config from the rollback snippet or reconstruct it manually. If it's stale data, force-deactivate then remove.

**Trailing characters after coloured output (e.g. `running1`, `online1`)**

Some terminal emulators (notably ZOC in default mode) mangle ANSI SGR reset sequences, echoing the last input character. Use `--no-color` to disable colour output:

```bash
sudo ./pct-renumber.sh --no-color
```

The included `zoc-diag.sh` script identifies which ANSI reset variants your terminal handles cleanly.

**Backspace produces `^?` or `^H` at prompts**

The script sets `stty erase '^?'` at startup. If your terminal sends `^H` instead, edit the stty line or use `--no-color` and rely on your shell's own line editing.

---

## Contributing

Pull requests are welcome. For significant changes please open an issue first to discuss the approach.

Please test against a multi-node PVE 9 cluster before submitting changes that affect migration or LVM operations.

---

## License

[MIT](LICENSE) — free to use, modify, and distribute. Attribution appreciated but not required.

---

*Giving back to the open source community that makes our work possible.*
