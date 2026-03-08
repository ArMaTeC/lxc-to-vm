# shrink-lxc.sh Guide

Documentation for optimizing LXC containers before conversion to reduce disk size.

---

## Overview

`shrink-lxc.sh` reduces LXC container disk usage by zero-filling free space, removing unnecessary files, and optionally resizing the filesystem. This is particularly useful before converting to VMs to minimize final disk size.

---

## Quick Start

```bash
# Basic shrink
sudo ./shrink-lxc.sh -c 100

# Shrink with resize
sudo ./shrink-lxc.sh -c 100 --resize

# Preview only
sudo ./shrink-lxc.sh -c 100 --dry-run
```

---

## Command Reference

| Short | Long | Description | Default |
| ----- | ---- | ----------- | ------- |
| `-c` | `--ctid` | Container ID | Prompted |
| `-n` | `--dry-run` | Preview without changes | — |
| `-r` | `--resize` | Resize filesystem after | — |
| `-s` | `--size` | Target size (e.g., 5G) | Auto-minimum |
| `-t` | `--temp-dir` | Working directory | `/var/lib/vz/dump` |
| `-h` | `--help` | Show help | — |
| `-V` | `--version` | Print version | — |

---

## Usage Examples

### Basic Container Shrink

```bash
sudo ./shrink-lxc.sh -c 100
```

### Shrink and Resize

```bash
sudo ./shrink-lxc.sh -c 100 --resize
```

### Shrink to Specific Size

```bash
sudo ./shrink-lxc.sh -c 100 --size 5G
```

### Dry-Run Preview

```bash
sudo ./shrink-lxc.sh -c 100 --dry-run
```

---

## How It Works

### Shrink Process

1. **Stop Container** (if running)
2. **Clean Files**
   - Remove package caches
   - Clear logs
   - Delete temp files
3. **Zero-Fill Free Space**
   - Fill empty space with zeros for better compression
4. **Calculate Minimum Size**
   - Analyze actual data usage
   - Add safety margin
5. **Resize Filesystem** (if `--resize`)
   - Resize ext4 filesystem
   - Adjust container disk allocation

---

## Best Practices

### Before Conversion

Always shrink before converting large containers:

```bash
sudo ./shrink-lxc.sh -c 100 --resize
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
- **[Hooks](Hooks)** - Pre/post shrink hooks
