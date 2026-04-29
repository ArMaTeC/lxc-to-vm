# shrink-vm.sh Guide

Documentation for shrinking a VM's disk to its actual usage in Proxmox VE.

---

## Overview

`shrink-vm.sh` safely shrinks a VM's primary disk to match its actual data usage plus configurable headroom. The VM is stopped during the operation and automatically restarted afterward. Supports LVM, ZFS, QCOW2, and raw disk formats with optional `libguestfs` (`virt-resize`) for more reliable shrinking of complex disk layouts.

---

## Quick Start

```bash
# Shrink VM 100 to usage + 2GB headroom (default)
sudo ./shrink-vm.sh -v 100

# Shrink with 5GB extra headroom
sudo ./shrink-vm.sh -v 100 -g 5

# Use libguestfs for safer shrink (requires libguestfs-tools)
sudo ./shrink-vm.sh -v 100 -u

# Preview changes without applying
sudo ./shrink-vm.sh -v 100 --dry-run
```

---

## Command Reference

| Short | Long | Description | Default |
| ----- | ---- | ----------- | ------- |
| `-v` | `--vmid <ID>` | VM ID to shrink | Prompted |
| `-g` | `--headroom <GB>` | Extra GB above used space | `2` |
| `-n` | `--dry-run` | Show what would be done without changes | — |
| `-u` | `--use-libguestfs` | Use `virt-resize` for safer shrink | — |
| | `--skip-fs-check` | Skip filesystem checks (not recommended) | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

---

## How It Works

1. **Stop VM** — VM is stopped (downtime required)
2. **Detect disk** — Primary disk detected (`scsi0`, `virtio0`, or `ide0`)
3. **Measure usage** — Actual data usage measured via `virt-df` (if available) or `qemu-img`
4. **Calculate target** — `used + metadata_margin + headroom`
5. **Filesystem check** — `e2fsck` run before shrinking
6. **Shrink filesystem** — `resize2fs` shrinks filesystem to target size
7. **Shrink storage** — LV, ZFS volume, or raw/QCOW2 image reduced
8. **Update config** — Proxmox VM config updated with new size
9. **Start VM** — VM restarted (if it was running)

---

## Size Calculation

The target size is calculated as:

```text
target = used_space + metadata_margin + headroom
```

- **`used_space`**: Actual data on disk (from `virt-df` or `qemu-img`, else estimated as 50% of current)
- **`metadata_margin`**: 5% of used space, minimum 512MB, rounded up to GB
- **`headroom`**: Configurable via `-g` (default: 2GB)
- **Minimum**: 2GB enforced

---

## Using libguestfs (`-u`)

When `libguestfs-tools` is installed, passing `-u` uses `virt-resize` for the shrink, which is more reliable for complex partition layouts (e.g., multiple partitions, LVM inside the VM):

```bash
# Install libguestfs-tools first
apt install libguestfs-tools

# Shrink using virt-resize
sudo ./shrink-vm.sh -v 100 -u
```

If `virt-resize` fails, the script automatically falls back to the standard `resize2fs` method.

---

## Storage & Format Support

| Storage Type | Format | Notes |
| ------------ | ------ | ----- |
| **LVM-thin** | raw (block) | `e2fsck` + `resize2fs` + `lvresize` |
| **LVM** | raw (block) | `e2fsck` + `resize2fs` + `lvresize` |
| **Directory** | QCOW2 | Convert to raw → shrink → convert back |
| **Directory** | raw | Loop-mount → `resize2fs` → `truncate` |
| **ZFS** | raw (zvol) | `resize2fs` + `zfs set volsize` |
| **NFS / CIFS** | any | Treated as directory storage |

---

## Dry-Run Mode

Preview what would happen without making any changes:

```bash
sudo ./shrink-vm.sh -v 100 --dry-run
```

---

## Safety Features

- **Dry-run mode** previews all changes before execution
- **VM is stopped** before any disk modification (no live disk writes)
- **Filesystem check** (`e2fsck`) before and after shrink
- **Minimum 2GB disk size** is enforced
- **Confirmation prompt** before destructive operations
- **VM restarted** automatically after shrink (if it was running)

---

## Internal Functions

| Function | Description |
| -------- | ----------- |
| `error_reason_and_fix()` | Maps a failed command to a human-readable reason and fix suggestion |
| `error_exit_code()` | Maps a failed command to a structured exit code |
| `on_error()` | Global ERR trap; logs context, reason, fix, and exits with mapped code |
| `usage()` | Prints full help text |
| `debug()` | Logs debug messages (when `SHRINK_VM_DEBUG=1`) |
| `verbose()` | Logs verbose messages to the log file |

---

## Exit Codes

| Code | Name | Meaning |
| ---- | ---- | ------- |
| `0` | Success | Shrink completed (or no shrink needed) |
| `1` | `E_INVALID_ARG` | Bad arguments or unknown option |
| `2` | `E_NOT_FOUND` | VM or storage not found |
| `3` | `E_DISK_FULL` | Disk space issue |
| `4` | `E_PERMISSION` | Permission denied |
| `5` | `E_SHRINK_FAILED` | Shrink operation failed |

---

## Debug Mode

Enable verbose debug output by setting `SHRINK_VM_DEBUG=1`:

```bash
SHRINK_VM_DEBUG=1 sudo ./shrink-vm.sh -v 100
```

Logs are written to `/var/log/shrink-vm.log`.

---

## Examples

### Shrink before migrating storage

```bash
sudo ./shrink-vm.sh -v 100
```

### Shrink with extra headroom for safety

```bash
sudo ./shrink-vm.sh -v 100 -g 10
```

### Reliable shrink using libguestfs

```bash
sudo ./shrink-vm.sh -v 100 -u
```

### Preview savings without changing anything

```bash
sudo ./shrink-vm.sh -v 100 --dry-run
```

---

## Related Documentation

- **[expand-vm.sh](expand-vm)** - Expand VM disks
- **[shrink-lxc.sh](shrink-lxc)** - Shrink LXC container disks
- **[clone-replace-disk.sh](clone-replace-disk)** - Clone disk after shrink for a clean result
- **[Troubleshooting](Troubleshooting)** - Common issues
