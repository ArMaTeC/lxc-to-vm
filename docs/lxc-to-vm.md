# lxc-to-vm.sh Complete Guide

Comprehensive documentation for converting Proxmox LXC containers to KVM virtual machines.

---

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Command Reference](#command-reference)
4. [Usage Examples](#usage-examples)
5. [How It Works](#how-it-works)
6. [Exit Codes](#exit-codes)
7. [Post-Conversion](#post-conversion)
8. [Troubleshooting](#troubleshooting)

---

## Overview

`lxc-to-vm.sh` converts Proxmox LXC containers into fully bootable KVM virtual machines with UEFI or BIOS support.

### Key Features

- **Intelligent Disk Shrinking** - Reduces container disk size before conversion
- **UEFI & BIOS Support** - Full boot mode compatibility
- **Network Preservation** - Keep or reconfigure network settings
- **Batch Processing** - Convert multiple containers at once
- **Snapshot Safety** - Automatic rollback on failure
- **Predictive Sizing** - AI-like disk size recommendations
- **Cloud Export** - Export to S3, NFS, or remote storage

---

## Quick Start

### Basic Conversion

```bash
# Interactive mode (prompts for all inputs)
sudo ./lxc-to-vm.sh

# Non-interactive with all required arguments
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm
```

### With Auto-Start

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --start
```

### Shrink + Convert

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start
```

---

## Command Reference

### Options Table

| Short | Long | Description | Default |
| ----- | ---- | ----------- | ------- |
| `-c` | `--ctid` | Source container ID | Prompted |
| `-v` | `--vmid` | Target VM ID | Prompted |
| `-s` | `--storage` | Proxmox storage name | Prompted |
| `-d` | `--disk-size` | Disk size in GB (e.g., 10G) | Auto-calculated |
| `-b` | `--bridge` | Network bridge | `vmbr0` |
| `-t` | `--temp-dir` | Working directory | `/var/lib/vz/dump` |
| `-n` | `--dry-run` | Preview without changes | — |
| `-S` | `--start` | Auto-start after conversion | — |
| `-k` | `--keep-network` | Preserve container network config | — |
| `-U` | `--uefi` | Create UEFI VM (BIOS default) | — |
| `-m` | `--memory` | VM memory in MB | From container |
| `-C` | `--cores` | VM CPU cores | From container |
| `-T` | `--tags` | VM tags (comma-separated) | None |
| `-D` | `--description` | VM description | Auto-generated |
| | `--shrink` | Shrink container first | — |
| | `--snapshot` | Create container snapshot first | — |
| | `--rollback-on-failure` | Auto-rollback on failure | — |
| | `--destroy-source` | Destroy container after success | — |
| | `--no-shrinking` | Skip disk shrinking | — |
| | `--resize-fs` | Resize filesystem after shrinking | — |
| | `--resume` | Resume interrupted conversion | — |
| | `--parallel` | Parallel batch processing | `1` |
| | `--batch` | Batch conversion from file | — |
| | `--range` | Range conversion (ct:vm range) | — |
| | `--wizard` | Interactive TUI wizard | — |
| | `--predict-size` | Use predictive sizing | — |
| | `--export-to` | Export disk to cloud/remote | — |
| | `--export-format` | Export format (raw/qcow2/vmdk) | `raw` |
| | `--sysprep` | Run Windows-style cleanup | — |
| | `--template` | Convert to VM template after | — |
| | `--save-profile` | Save options as profile | — |
| | `--profile` | Load options from profile | — |
| | `--list-profiles` | List saved profiles | — |
| | `--migrate-to-local` | Migrate container to local node | — |
| | `--api-host` | Proxmox API host | — |
| | `--api-token` | Proxmox API token | — |
| | `--api-user` | Proxmox API user | `root@pam` |
| | `--validate-only` | Run pre-flight checks only | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

---

## Usage Examples

### Basic Conversion (Non-Interactive)

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm
```

### Shrink + Convert + Auto-Start

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start
```

### UEFI Boot Mode

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --uefi --start
```

### Dry-Run Preview

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --dry-run
```

### Keep Existing Network Config

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --keep-network
```

### Safe Conversion with Snapshot

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --snapshot --rollback-on-failure --start
```

### Batch Conversion from File

```bash
# Create conversions.txt:
# CTID VMID [storage] [disk-size]
cat > conversions.txt << 'EOF'
100 200 local-lvm 10G
101 201 local-lvm 15G
102 202
EOF

sudo ./lxc-to-vm.sh --batch conversions.txt
```

### Parallel Batch Processing

```bash
# Convert 4 containers simultaneously
sudo ./lxc-to-vm.sh --batch conversions.txt --parallel 4
```

### Range Conversion

```bash
# Convert CTs 100-110 to VMs 200-210
sudo ./lxc-to-vm.sh --range 100-110:200-210 -s local-lvm
```

### Export to S3

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --export-to s3://mybucket/vm-images/ \
  --export-format qcow2
```

### Create VM Template

```bash
sudo ./lxc-to-vm.sh -c 100 -v 9000 -s local-lvm --template
```

### Wizard Mode

```bash
sudo ./lxc-to-vm.sh --wizard
```

---

## How It Works

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                    LXC TO VM CONVERSION PIPELINE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐          │
│  │  SOURCE  │───→│ VALIDATE │───→│  SHRINK  │───→│ SNAPSHOT │          │
│  │ LXC CT   │    │   CTID   │    │  (opt)   │    │  (opt)   │          │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘          │
│       │                │               │               │               │
│       ↓                ↓               ↓               ↓               │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    CONVERSION PHASE                              │   │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐   │   │
│  │  │  CREATE  │───→│  COPY    │───→│ INJECT   │───→│  CONFIG  │   │   │
│  │  │ DISK IMG │    │ RSYNC    │    │ BOOTLOAD │    │   VM     │   │   │
│  │  └──────────┘    └──────────┘    └──────────┘    └──────────┘   │   │
│  │       │               │              │              │          │   │
│  │       ↓               ↓              ↓              ↓          │   │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐                   │   │
│  │  │ PARTITION│    │ ROOTFS   │    │ NETWORK  │                   │   │
│  │  │  & FS    │    │  DATA    │    │   CONFIG │                   │   │
│  │  └──────────┘    └──────────┘    └──────────┘                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│       │                                                                │
│       ↓                                                                │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                         │
│  │  IMPORT  │───→│   BOOT   │───→│ HEALTH   │                         │
│  │  TO PVE  │    │  ORDER   │    │  CHECK   │                         │
│  └──────────┘    └──────────┘    └──────────┘                         │
│       │                              │                                │
│       ↓                              ↓                                │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                         │
│  │  START   │    │ CLEANUP  │    │  DESTROY │                         │
│  │   VM     │    │  (opt)   │    │   CT     │                         │
│  └──────────┘    └──────────┘    └──────────┘                         │
│       │                                                                │
│       ↓                                                                │
│  ┌──────────┐                                                          │
│  │   DONE   │                                                          │
│  │   🎉     │                                                          │
│  └──────────┘                                                          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Detailed Process

1. **Validation Phase**
   - Verify container exists and is accessible
   - Check container filesystem type (ext4, xfs, btrfs supported)
   - Validate target storage availability
   - Check disk space requirements

2. **Shrink Phase (Optional)**
   - Zero-fill free space for better compression
   - Calculate minimum required disk size
   - Resize filesystem (ext4 only)
   - Adjust container disk allocation

3. **Snapshot Phase (Optional)**
   - Create LXC snapshot for rollback safety
   - Store snapshot metadata for recovery

4. **Disk Creation**
   - Create raw disk image file
   - Partition as GPT (UEFI) or MBR (BIOS)
   - Create filesystem (ext4 default)
   - Mount via loop device

5. **Data Copy**
   - Use `rsync` for efficient file transfer
   - Preserve permissions and ownership
   - Handle special files and symlinks
   - Progress reporting

6. **Bootloader Injection**
   - Chroot into disk image
   - Install kernel and bootloader
   - Configure GRUB2 (Debian/Ubuntu/RHEL) or Syslinux (Alpine)
   - Setup EFI partition (UEFI mode)

7. **Network Configuration**
   - Detect container network settings
   - Map to VM network (eth0 → ens18 default)
   - Optionally preserve original config

8. **VM Creation**
   - Import disk to Proxmox storage
   - Create VM configuration
   - Set CPU, memory, network from container
   - Configure boot order

9. **Health Checks**
   - Verify VM boots successfully
   - Check QEMU agent connectivity
   - Test network connectivity
   - Validate root filesystem

---

## Exit Codes

| Code | Name | Description |
| ---- | ---- | ----------- |
| `0` | `E_SUCCESS` | ✅ Conversion successful |
| `1` | `E_INVALID_ARG` | ❌ Invalid arguments provided |
| `2` | `E_NOT_FOUND` | ❌ Container/storage not found |
| `3` | `E_DISK_FULL` | ❌ Insufficient disk space |
| `4` | `E_PERMISSION` | ❌ Permission denied |
| `5` | `E_MIGRATION` | ❌ Cluster migration failed |
| `6` | `E_CONVERSION` | ❌ Core conversion failed |
| `7` | `E_NETWORK` | ❌ Network configuration error |
| `8` | `E_BOOTLOADER` | ❌ Bootloader installation failed |
| `9` | `E_DEPENDENCY` | ❌ Missing dependency |
| `10` | `E_INTERRUPTED` | ❌ Interrupted by user |
| `11` | `E_ROLLBACK_FAILED` | ❌ Rollback failed |
| `12` | `E_EXPORT_FAILED` | ❌ Cloud export failed |
| `13` | `E_TEMPLATE_FAILED` | ❌ Template conversion failed |
| `14` | `E_HOOK_FAILED` | ❌ Hook execution failed |
| `15` | `E_HEALTH_CHECK` | ❌ Post-conversion health check failed |
| `16` | `E_SHRINK_FAILED` | ❌ Disk shrinking failed |
| `100` | `E_BATCH_PARTIAL` | ⚠️ Batch had partial failures |
| `101` | `E_BATCH_ALL` | ❌ Batch completely failed |

---

## Post-Conversion

### Start and Verify the VM

```bash
# Start the VM
qm start 200

# Check status
qm status 200

# Open console
qm console 200

# Or use VNC/SPICE
```

### Verify Network

```bash
# Check VM network config
qm config 200 | grep net0

# Get IP from QEMU agent
qm agent 200 network-get-interfaces
```

### Clean Up

```bash
# Remove original container (after confirming VM works)
pct stop 100
pct destroy 100
```

### Update VM Description

```bash
# Add notes about conversion
qm set 200 --description "Converted from CT 100 on $(date)"
```

---

## Troubleshooting

### VM Won't Boot

**Check boot disk:**

```bash
qm config 200 | grep -E '^(scsi|virtio|ide|sata)'
```

**Verify bootloader:**

```bash
# Mount VM disk and check
qm stop 200
# Mount disk and verify /boot exists
```

**Check VM logs:**

```bash
# View serial console output
qm console 200

# Check task log
cat /var/log/lxc-to-vm.log
```

### Network Issues

**No network connectivity:**

```bash
# Check network config
qm config 200 | grep net0

# Verify bridge exists
ip link show vmbr0

# Check QEMU agent
qm agent 200 ping
```

**Wrong interface name:**

```bash
# VM should have ens18, not eth0
# If using --keep-network, interface will be eth0
```

### Disk Space Issues

**Not enough space:**

```bash
# Check available space
pvesm status | grep local-lvm

# Use smaller disk size
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 5G

# Or use --shrink first
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink
```

### Container Not Found

```bash
# List all containers
pct list

# Verify CTID exists
pct config 100
```

---

## Related Documentation

- **[vm-to-lxc.sh](vm-to-lxc)** - Reverse conversion (VM to LXC)
- **[shrink-lxc.sh](shrink-lxc)** - Container optimization
- **[Hooks](Hooks)** - Custom automation hooks
- **[Troubleshooting](Troubleshooting)** - Common issues and fixes
