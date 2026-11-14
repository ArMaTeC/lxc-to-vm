<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: shrink-lxc.md
     Description: Shrink lxc
     License: MIT
     ============================================================================== -->
# shrink-lxc.sh Guide

Documentation for shrinking an LXC container's root disk to actual usage in Proxmox VE.

---

## Overview

`shrink-lxc.sh` reduces an LXC container's root disk to its actual data usage plus configurable headroom. The container is stopped during the operation and automatically restarted afterward. This is particularly useful before converting to a VM with `lxc-to-vm.sh` to minimize the target disk size. Supports LVM/LVM-thin, directory (raw/qcow2), and ZFS storage.

---

## Quick Start

```bash
# Basic shrink to usage + 1GB headroom (default)
sudo ./shrink-lxc.sh -c 100

# Shrink with 2GB extra headroom
sudo ./shrink-lxc.sh -c 100 -g 2

# Preview only
sudo ./shrink-lxc.sh -c 100 --dry-run

# Batch shrink multiple containers, auto-accepting confirmations
sudo ./shrink-lxc.sh -c 100,101,102 -y
```

---

## Command Reference

| Short | Long | Description | Default |
| ----- | ---- | ----------- | ------- |
| `-c` | `--ctid <ID>` | Container ID(s) to shrink — repeat flag or comma/space list | Prompted |
| `-g` | `--headroom <GB>` | Extra GB above used space | `1` |
| `-n` | `--dry-run` | Preview without changes | — |
| `-y` | `--yes` | Non-interactive: auto-accept confirmations | — |
| `-h` | `--help` | Show help | — |
| `-V` | `--version` | Print version | — |

Bare numeric arguments are also accepted as container IDs (e.g., `./shrink-lxc.sh 100 101`).

---

## Batch Mode

Passing more than one container ID runs the script in batch mode: each container is processed in turn by a fresh single-ID run, and a summary is printed at the end.

```bash
sudo ./shrink-lxc.sh -c 100,101,102 -y      # comma list
sudo ./shrink-lxc.sh -c 100 -c 101 -c 102   # repeated flag
sudo ./shrink-lxc.sh 100 101 102 --yes      # positional IDs
```

- A failure on one container does **not** abort the batch — the error is reported (hands-on attention needed) and processing continues with the next ID.
- Declining the confirmation prompt marks that container as *skipped*; without `--yes` you are prompted per container.
- The script exits non-zero (`5`, `E_SHRINK_FAILED`) if any container failed, `0` otherwise.

---

## Usage Examples

### Basic Container Shrink

```bash
sudo ./shrink-lxc.sh -c 100
```

### Shrink with Extra Headroom

```bash
sudo ./shrink-lxc.sh -c 100 -g 2
```

### Dry-Run Preview

```bash
sudo ./shrink-lxc.sh -c 100 --dry-run
```

---

## How It Works

1. **Stop Container** (if running)
2. **Mount rootfs** and measure actual usage with `du` (excluding `dev`, `proc`, `sys`, `tmp`, `run`)
3. **Calculate target**: `used + metadata margin (5%, min 512MB) + headroom`, minimum 2GB
4. **Filesystem check** (`e2fsck`) before shrinking
5. **Shrink filesystem** (`resize2fs`, with retry on LVM)
6. **Shrink storage**: `lvresize` for LVM, `truncate`/`qemu-img` for directory images, `zfs set volsize` for ZFS
7. **Update container config** (`pct set --rootfs`)
8. **Restart container** (if it was running)

---

## Exit Codes

| Code | Name | Meaning |
| ---- | ---- | ------- |
| `0` | Success | Shrink completed (or no shrink needed) |
| `1` | `E_INVALID_ARG` | Bad arguments or unknown option |
| `2` | `E_NOT_FOUND` | Container or resource not found |
| `3` | `E_DISK_FULL` | Disk space issue |
| `4` | `E_PERMISSION` | Permission denied |
| `5` | `E_SHRINK_FAILED` | Shrink operation failed (also: batch mode with ≥1 failure) |
| `10` | `E_ABORT` | Aborted by user at the confirmation prompt |

---

## Best Practices

### Before Conversion

Always shrink before converting large containers:

```bash
sudo ./shrink-lxc.sh -c 100
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm
```

### Automatic Cleanup

Create a pre-shrink hook for custom cleanup:

```bash
# /var/lib/lxc-to-vm/hooks/pre-shrink
#!/bin/bash
CTID=$1
# Custom cleanup
pct exec $CTID -- apt-get clean
pct exec $CTID -- rm -rf /var/log/*.log.*
```

---

## Related Documentation

- **[lxc-to-vm.sh](lxc-to-vm)** - Convert after shrinking
- **[shrink-vm.sh](shrink-vm)** - Shrink VM disks
- **[Hooks](Hooks)** - Pre/post shrink hooks
