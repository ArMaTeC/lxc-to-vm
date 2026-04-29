# expand-lxc.sh Guide

Documentation for expanding an LXC container's root disk in Proxmox VE.

---

## Overview

`expand-lxc.sh` safely expands an LXC container's root disk to a specified size. It supports multiple expansion modes, all major Proxmox storage backends, and optional hot-expansion (no container restart required for supported storage types).

---

## Quick Start

```bash
# Expand container 100 to exactly 100GB
sudo ./expand-lxc.sh -c 100 -s 100

# Add 50GB to current size
sudo ./expand-lxc.sh -c 100 -a 50

# Use maximum available pool space (with safety margin)
sudo ./expand-lxc.sh -c 100 --max

# Preview changes without applying
sudo ./expand-lxc.sh -c 100 -a 20 --dry-run
```

---

## Command Reference

| Short | Long | Description | Default |
| ----- | ---- | ----------- | ------- |
| `-c` | `--ctid <ID>` | Container ID to expand | Prompted |
| `-s` | `--size <GB>` | Set absolute target size in GB | — |
| `-a` | `--add <GB>` | Add specified GB to current size | — |
| | `--percent <N>` | Expand to N% of pool capacity | — |
| | `--max` | Use maximum available space (with safety margin) | — |
| | `--fill-free` | Alias for `--max` (deprecated) | — |
| `-n` | `--dry-run` | Show what would be done without changes | — |
| | `--safety-margin <GB>` | GB to keep free when using `--max` | `10` |
| | `--safety-percent <N>` | Percent of pool to keep free when using `--max` | `5` |
| | `--no-restart` | Keep container running (hot-expand where supported) | — |
| | `--force` | Skip confirmation prompts | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

---

## Expansion Modes

### Absolute Size (`-s`)

Sets the disk to an exact target size in GB. The target must be larger than the current size.

```bash
sudo ./expand-lxc.sh -c 100 -s 100
```

### Add Space (`-a`)

Adds a fixed number of GB to the current disk size.

```bash
sudo ./expand-lxc.sh -c 100 -a 50
```

### Percentage (`--percent`)

Expands the disk to a percentage of the total storage pool capacity.

```bash
sudo ./expand-lxc.sh -c 100 --percent 80
```

### Maximum (`--max`)

Expands to the maximum available free space in the pool, minus a configurable safety margin.

```bash
# Default safety margin (10GB or 5%)
sudo ./expand-lxc.sh -c 100 --max

# Custom safety margin
sudo ./expand-lxc.sh -c 100 --max --safety-margin 20
```

---

## Storage Support

| Storage Type | Hot-Expand | Notes |
| ------------ | ---------- | ----- |
| **LVM-thin** | ✅ Yes | Proxmox default; most efficient |
| **LVM** | ✅ Yes | Thick provisioning |
| **Directory (raw)** | ✅ Yes | Loop-mounted raw image |
| **Directory (qcow2)** | ⚠️ Partial | Requires `qemu-nbd` for filesystem resize |
| **ZFS** | ✅ Yes | ZVOL resize |
| **NFS / CIFS** | ❌ No | Requires container restart |

---

## Hot-Expand (No Restart)

For LVM, LVM-thin, ZFS, and raw directory storage, the container can remain running during expansion using `--no-restart`:

```bash
sudo ./expand-lxc.sh -c 100 -s 200 --no-restart
```

If the storage type does not support hot-expansion, the container will be stopped and restarted automatically.

---

## Dry-Run Mode

Preview the exact steps that would be performed without making any changes:

```bash
sudo ./expand-lxc.sh -c 100 -a 50 --dry-run
```

Example output:

```text
=== DRY RUN — No changes will be made ===

  Container:    100
  Status:       running
  Storage:      local-lvm (lvmthin)
  Current disk: 32GB
  Target size:  82GB
  Expansion:    +50GB
  Mode:         add

  Steps that would be performed:
    1. No restart required (hot-expand mode)
    2. Expand LV with lvresize to 82GB
    3. Expand filesystem with resize2fs
    4. Update container config
    5. Verify filesystem integrity
```

---

## Safety Features

- **Dry-run mode** previews all changes before execution
- **Automatic pool space validation** prevents expanding beyond available capacity
- **Safety margins** on `--max` mode reserve pool space (default: 10GB or 5%)
- **Filesystem integrity check** (`e2fsck`) runs after expansion
- **Minimum disk size** of 2GB is enforced

---

## Internal Functions

| Function | Description |
| -------- | ----------- |
| `get_pool_free_space()` | Queries free space in the container's storage pool (LVM, ZFS, or directory) |
| `get_pool_total_size()` | Queries total capacity of the storage pool |
| `calculate_target_size()` | Resolves the expansion mode into a concrete target GB value |
| `error_reason_and_fix()` | Maps a failed command to a human-readable reason and fix suggestion |
| `error_exit_code()` | Maps a failed command to a structured exit code |
| `on_error()` | Global ERR trap; logs context, reason, fix, and exits with mapped code |
| `usage()` | Prints full help text |
| `debug()` | Logs debug messages (when `EXPAND_LXC_DEBUG=1`) |
| `verbose()` | Logs verbose messages to the log file |

---

## Exit Codes

| Code | Name | Meaning |
| ---- | ---- | ------- |
| `0` | Success | Expansion completed |
| `1` | `E_INVALID_ARG` | Bad arguments or unknown option |
| `2` | `E_NOT_FOUND` | Container or storage not found |
| `3` | `E_DISK_FULL` | Disk space issue |
| `4` | `E_PERMISSION` | Permission denied |
| `5` | `E_EXPAND_FAILED` | Expansion operation failed |
| `6` | `E_NO_SPACE` | Insufficient pool space |

---

## Debug Mode

Enable verbose debug output by setting `EXPAND_LXC_DEBUG=1`:

```bash
EXPAND_LXC_DEBUG=1 sudo ./expand-lxc.sh -c 100 -a 20
```

Logs are written to `/var/log/expand-lxc.log`.

---

## Examples

### Expand before a major update

```bash
sudo ./expand-lxc.sh -c 100 -a 20
```

### Expand to fill available pool space

```bash
sudo ./expand-lxc.sh -c 100 --max --safety-margin 15
```

### Expand without restarting the container

```bash
sudo ./expand-lxc.sh -c 100 -s 150 --no-restart
```

### Automated non-interactive expansion

```bash
sudo ./expand-lxc.sh -c 100 -a 50 --force
```

---

## Post-Expansion Verification

After expanding, verify the new space is available inside the container:

```bash
pct exec 100 -- df -h /
```

---

## Related Documentation

- **[shrink-lxc.sh](shrink-lxc)** - Shrink container disks
- **[expand-vm.sh](expand-vm)** - Expand VM disks
- **[clone-replace-disk.sh](clone-replace-disk)** - Clone disk if expansion is not recognized by guest
- **[Troubleshooting](Troubleshooting)** - Common issues
