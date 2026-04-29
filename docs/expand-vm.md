# expand-vm.sh Guide

Documentation for expanding a VM's disk in Proxmox VE.

---

## Overview

`expand-vm.sh` safely expands a VM's primary disk to a specified size. It supports multiple expansion modes, all major Proxmox storage backends, QCOW2 and raw image formats, and optional hot-expansion so the VM can remain running during the resize.

---

## Quick Start

```bash
# Expand VM 100 to exactly 100GB
sudo ./expand-vm.sh -v 100 -s 100

# Add 50GB to current size
sudo ./expand-vm.sh -v 100 -a 50

# Use maximum available pool space (with safety margin)
sudo ./expand-vm.sh -v 100 --max

# Hot-expand while VM is running
sudo ./expand-vm.sh -v 100 -s 200 --hot-expand

# Preview changes without applying
sudo ./expand-vm.sh -v 100 -a 20 --dry-run
```

---

## Command Reference

| Short | Long | Description | Default |
| ----- | ---- | ----------- | ------- |
| `-v` | `--vmid <ID>` | VM ID to expand | Prompted |
| `-s` | `--size <GB>` | Set absolute target size in GB | — |
| `-a` | `--add <GB>` | Add specified GB to current size | — |
| | `--percent <N>` | Expand to N% of pool capacity | — |
| | `--max` | Use maximum available space (with safety margin) | — |
| `-n` | `--dry-run` | Show what would be done without changes | — |
| | `--safety-margin <GB>` | GB to keep free when using `--max` | `10` |
| | `--safety-percent <N>` | Percent of pool to keep free when using `--max` | `5` |
| | `--hot-expand` | Attempt online expansion (VM stays running) | — |
| | `--no-restart` | Keep VM stopped after expansion | — |
| | `--force` | Skip confirmation prompts | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

---

## Expansion Modes

### Absolute Size (`-s`)

Sets the disk to an exact target size in GB. The target must be larger than the current size.

```bash
sudo ./expand-vm.sh -v 100 -s 100
```

### Add Space (`-a`)

Adds a fixed number of GB to the current disk size.

```bash
sudo ./expand-vm.sh -v 100 -a 50
```

### Percentage (`--percent`)

Expands the disk to a percentage of the total storage pool capacity.

```bash
sudo ./expand-vm.sh -v 100 --percent 80
```

### Maximum (`--max`)

Expands to the maximum available free space in the pool, minus a configurable safety margin.

```bash
sudo ./expand-vm.sh -v 100 --max
sudo ./expand-vm.sh -v 100 --max --safety-margin 20
```

---

## Hot-Expand (VM Stays Running)

Use `--hot-expand` to expand the disk while the VM is running. The script expands the underlying storage and notifies the VM via the QEMU monitor (`block_resize`). After the disk is expanded, you must resize the filesystem **inside** the VM:

```bash
sudo ./expand-vm.sh -v 100 -s 200 --hot-expand
```

Then inside the VM:

```bash
# Check the new disk size
lsblk

# Resize the partition (if needed)
growpart /dev/sda 1

# Resize the filesystem
resize2fs /dev/sda1
```

Hot-expand is supported for: LVM-thin, LVM, ZFS, and directory (QCOW2/raw) storage.

---

## Storage & Format Support

| Storage Type | Format | Hot-Expand | Notes |
| ------------ | ------ | ---------- | ----- |
| **LVM-thin** | raw (block) | ✅ Yes | Most common Proxmox default |
| **LVM** | raw (block) | ✅ Yes | Thick provisioning |
| **Directory** | QCOW2 | ✅ Yes | Uses `qemu-img resize` + QEMU monitor |
| **Directory** | raw | ✅ Yes | Uses `qemu-img resize` + QEMU monitor |
| **ZFS** | raw (zvol) | ✅ Yes | Uses `zfs set volsize` |
| **NFS / CIFS** | any | ❌ No | Requires VM stop |

---

## Dry-Run Mode

Preview the exact steps that would be performed without making any changes:

```bash
sudo ./expand-vm.sh -v 100 -a 50 --dry-run
```

---

## Safety Features

- **Dry-run mode** previews all changes before execution
- **Automatic pool space validation** prevents expanding beyond available capacity
- **Safety margins** on `--max` mode reserve pool space (default: 10GB or 5%)
- **Minimum disk size** of 2GB is enforced
- **Confirmation prompt** before destructive operations (bypass with `--force`)

---

## Internal Functions

| Function | Description |
| -------- | ----------- |
| `get_pool_free_space()` | Queries free space in the VM's storage pool |
| `get_pool_total_size()` | Queries total capacity of the storage pool |
| `calculate_target_size()` | Resolves the expansion mode into a concrete target GB value |
| `error_reason_and_fix()` | Maps a failed command to a human-readable reason and fix suggestion |
| `error_exit_code()` | Maps a failed command to a structured exit code |
| `on_error()` | Global ERR trap; logs context, reason, fix, and exits with mapped code |
| `usage()` | Prints full help text |
| `debug()` | Logs debug messages (when `EXPAND_VM_DEBUG=1`) |
| `verbose()` | Logs verbose messages to the log file |

---

## Exit Codes

| Code | Name | Meaning |
| ---- | ---- | ------- |
| `0` | Success | Expansion completed |
| `1` | `E_INVALID_ARG` | Bad arguments or unknown option |
| `2` | `E_NOT_FOUND` | VM or storage not found |
| `3` | `E_DISK_FULL` | Disk space issue |
| `4` | `E_PERMISSION` | Permission denied |
| `5` | `E_EXPAND_FAILED` | Expansion operation failed |
| `6` | `E_NO_SPACE` | Insufficient pool space |

---

## Debug Mode

Enable verbose debug output by setting `EXPAND_VM_DEBUG=1`:

```bash
EXPAND_VM_DEBUG=1 sudo ./expand-vm.sh -v 100 -a 20
```

Logs are written to `/var/log/expand-vm.log`.

---

## Examples

### Expand to specific size

```bash
sudo ./expand-vm.sh -v 100 -s 100
```

### Add space to running VM without downtime

```bash
sudo ./expand-vm.sh -v 100 -a 50 --hot-expand
```

### Expand to fill available pool space

```bash
sudo ./expand-vm.sh -v 100 --max --safety-margin 15
```

### Automated non-interactive expansion

```bash
sudo ./expand-vm.sh -v 100 -s 200 --force
```

---

## Post-Expansion Notes

After expanding the disk, the filesystem **inside** the VM must be resized manually if hot-expand was used, or verified if the VM was stopped:

```bash
# Inside the VM
lsblk
resize2fs /dev/sda1
df -h /
```

---

## Related Documentation

- **[shrink-vm.sh](shrink-vm)** - Shrink VM disks
- **[expand-lxc.sh](expand-lxc)** - Expand LXC container disks
- **[clone-replace-disk.sh](clone-replace-disk)** - Clone disk if expansion is not recognized by guest
- **[Troubleshooting](Troubleshooting)** - Common issues
