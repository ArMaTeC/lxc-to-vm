# clone-replace-disk.sh Guide

Documentation for cloning and replacing VM or LXC container disks in Proxmox VE.

---

## Overview

`clone-replace-disk.sh` clones a VM or LXC disk to a new volume (optionally resized or on a different storage backend) and then replaces the active disk with the clone. It is the recommended solution when:

- Proxmox shows an expanded disk size but the guest OS does not see the new space
- You want to migrate a disk to a different storage backend (e.g., from `local-lvm` to ZFS)
- You need a fresh, correctly-sized clone of a disk

The original disk is **kept by default** as a backup. Use `--remove-old` only when you are certain the new disk is working correctly.

---

## Quick Start

```bash
# Clone LXC 100 disk and expand to 200GB
sudo ./clone-replace-disk.sh -t lxc -i 100 --size 200

# Clone VM 200 primary disk (auto-detect)
sudo ./clone-replace-disk.sh -t vm -i 200

# Clone to different storage backend
sudo ./clone-replace-disk.sh -t lxc -i 100 -s zfspool --size 200

# Clone VM specific disk
sudo ./clone-replace-disk.sh -t vm -i 200 -d scsi0 --size 300

# Clone, replace, and remove old disk
sudo ./clone-replace-disk.sh -t vm -i 200 --size 250 --remove-old

# Preview changes without applying
sudo ./clone-replace-disk.sh -t lxc -i 100 --size 200 --dry-run
```

---

## Command Reference

| Short | Long | Description | Default |
| ----- | ---- | ----------- | ------- |
| `-t` | `--type <lxc\|vm>` | Target type: `lxc` or `vm` | Prompted |
| `-i` | `--id <ID>` | VM or Container ID | Prompted |
| `-d` | `--disk <NAME>` | Disk name for VMs (e.g., `scsi0`, `virtio0`) | Auto-detect |
| `-s` | `--storage <NAME>` | Target storage for clone | Same as source |
| | `--size <GB>` | Target size for clone in GB | Same as source |
| | `--format <raw\|qcow2>` | Target image format | Same as source |
| | `--name <NAME>` | Custom name for cloned volume | Auto-generated |
| | `--remove-old` | Remove old disk after replace (irreversible) | Off |
| | `--snapshot` | Create VM snapshot before operations | Off |
| | `--keep-old` | Explicitly keep old disk (default behavior) | On |
| `-n` | `--dry-run` | Show what would be done without changes | — |
| | `--force` | Skip confirmation prompts | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

---

## Workflow

```text
1. Stop VM/Container
2. Clone source disk → target disk (with optional resize)
3. Detach old disk from config (kept as backup by default)
4. Attach new disk to config
5. Expand filesystem on new disk (if size increased)
6. Remove old disk (only if --remove-old specified)
7. Start VM/Container
```

---

## Use Cases

### Fix: OS not seeing expanded disk size

When Proxmox shows a larger disk but the guest OS reports the old size, a fresh clone resolves the mismatch:

```bash
sudo ./clone-replace-disk.sh -t lxc -i 133 --size 200
```

### Migrate disk between storage backends

```bash
# Migrate LXC disk from local-lvm to ZFS
sudo ./clone-replace-disk.sh -t lxc -i 100 -s zfspool --size 200

# Migrate VM disk from directory to LVM-thin
sudo ./clone-replace-disk.sh -t vm -i 200 -s local-lvm
```

### Clone with format conversion

```bash
# Clone VM disk, convert QCOW2 to raw
sudo ./clone-replace-disk.sh -t vm -i 200 --format raw
```

### Create snapshot before cloning (VMs only)

```bash
sudo ./clone-replace-disk.sh -t vm -i 200 --size 300 --snapshot
```

---

## Storage Support

| Source Storage | Target Storage | Supported |
| -------------- | -------------- | --------- |
| LVM-thin | LVM-thin | ✅ |
| LVM-thin | ZFS | ✅ |
| LVM-thin | Directory | ✅ |
| Directory | LVM-thin | ✅ |
| Directory | ZFS | ✅ |
| ZFS | LVM-thin | ✅ |
| ZFS | Directory | ✅ |

Cross-storage cloning is fully supported. The script uses `qemu-img convert` to copy between incompatible formats.

---

## Safety Features

- **Dry-run mode** previews all steps before execution
- **Original disk kept by default** — only removed with `--remove-old`
- **Automatic rollback on failure** — restores original config if replace fails
- **Confirmation prompt** before destructive operations
- **Optional snapshot** before operations (VM only)

---

## Removing the Old Disk

After verifying the cloned disk works, remove the old disk manually:

```bash
pvesm free local-lvm:vm-100-disk-0
```

Or use `--remove-old` to do this automatically (use with caution — irreversible):

```bash
sudo ./clone-replace-disk.sh -t lxc -i 100 --size 200 --remove-old
```

---

## Internal Functions

| Function | Description |
| -------- | ----------- |
| `error_reason_and_fix()` | Maps a failed command to a human-readable reason and fix suggestion |
| `error_exit_code()` | Maps a failed command to a structured exit code |
| `on_error()` | Global ERR trap; attempts rollback of config, then exits with mapped code |
| `usage()` | Prints full help text |
| `debug()` | Logs debug messages (when `CLONE_REPLACE_DEBUG=1`) |
| `verbose()` | Logs verbose messages to the log file |

---

## Exit Codes

| Code | Name | Meaning |
| ---- | ---- | ------- |
| `0` | Success | Clone and replace completed |
| `1` | `E_INVALID_ARG` | Bad arguments or unknown option |
| `2` | `E_NOT_FOUND` | VM/Container or storage not found |
| `3` | `E_DISK_FULL` | Insufficient storage space |
| `4` | `E_PERMISSION` | Permission denied |
| `5` | `E_CLONE_FAILED` | Disk clone operation failed |
| `6` | `E_REPLACE_FAILED` | Configuration update failed |

---

## Debug Mode

Enable verbose debug output by setting `CLONE_REPLACE_DEBUG=1`:

```bash
CLONE_REPLACE_DEBUG=1 sudo ./clone-replace-disk.sh -t vm -i 200 --size 300
```

Logs are written to `/var/log/clone-replace-disk.log`.

---

## Examples

### Expand LXC disk by cloning (recommended fix for guest not seeing size)

```bash
sudo ./clone-replace-disk.sh -t lxc -i 133 --size 200
# Verify inside container
pct exec 133 -- df -h /
# Remove old when ready
pvesm free local-lvm:vm-133-disk-0
```

### Migrate VM disk to ZFS with resize

```bash
sudo ./clone-replace-disk.sh -t vm -i 200 -d scsi0 -s zfspool --size 300
```

### Non-interactive automated replace

```bash
sudo ./clone-replace-disk.sh -t lxc -i 100 --size 150 --force
```

---

## Related Documentation

- **[expand-lxc.sh](expand-lxc)** - Direct LXC disk expansion (no clone)
- **[expand-vm.sh](expand-vm)** - Direct VM disk expansion (no clone)
- **[shrink-lxc.sh](shrink-lxc)** - Shrink LXC container disks
- **[shrink-vm.sh](shrink-vm)** - Shrink VM disks
- **[Troubleshooting](Troubleshooting)** - Common issues
