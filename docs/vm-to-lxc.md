# vm-to-lxc.sh Complete Guide

Comprehensive documentation for converting Proxmox KVM virtual machines to LXC containers.

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

`vm-to-lxc.sh` converts Proxmox KVM virtual machines into LXC containers, extracting the VM filesystem, cleaning VM-specific artifacts, and creating a new container.

### Key Features

- **Automatic VM Disk Detection** - Supports virtio, SCSI, IDE, SATA disks
- **VM Artifact Cleanup** - Removes kernels, bootloaders, VM-specific packages
- **Network Reconfiguration** - Converts VM network (ens18) to LXC (eth0)
- **Unprivileged Container Support** - Create secure unprivileged containers
- **Snapshot & Rollback** - VM snapshots for safety
- **Batch Processing** - Convert multiple VMs at once
- **Predictive Sizing** - Analyze VM filesystem for optimal disk size

---

## Quick Start

### Basic Conversion

```bash
# Interactive mode (prompts for all inputs)
sudo ./vm-to-lxc.sh

# Non-interactive with all required arguments
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm
```

### With Auto-Start

```bash
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm --start
```

### With Snapshot Safety

```bash
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm \
  --snapshot --rollback-on-failure --start
```

---

## Command Reference

### Options Table

| Short | Long | Description | Default |
| ----- | ---- | ----------- | ------- |
| `-v` | `--vmid` | Source VM ID | Prompted |
| `-c` | `--ctid` | Target container ID | Prompted |
| `-s` | `--storage` | Proxmox storage name | Prompted |
| `-d` | `--disk-size` | Container disk size in GB | Auto-calculated |
| `-b` | `--bridge` | Network bridge name | `vmbr0` |
| `-t` | `--temp-dir` | Working directory | `/var/lib/vz/dump` |
| `-n` | `--dry-run` | Preview without changes | — |
| `-k` | `--keep-network` | Preserve original network config | — |
| `-S` | `--start` | Auto-start after conversion | — |
| | `--snapshot` | Create VM snapshot before | — |
| | `--rollback-on-failure` | Auto-rollback on failure | — |
| | `--destroy-source` | Destroy VM after success | — |
| | `--replace-ct` | Replace existing container | — |
| | `--resume` | Resume interrupted conversion | — |
| | `--parallel` | Parallel batch processing | `1` |
| | `--batch` | Batch conversion from file | — |
| | `--range` | Range conversion | — |
| | `--wizard` | Interactive TUI wizard | — |
| | `--predict-size` | Use predictive sizing | — |
| | `--unprivileged` | Create unprivileged container | — |
| | `--password` | Set root password | — |
| | `--save-profile` | Save options as profile | — |
| | `--profile` | Load options from profile | — |
| | `--list-profiles` | List saved profiles | — |
| | `--migrate-to-local` | Migrate VM to local node | — |
| | `--api-host` | Proxmox API host | — |
| | `--api-token` | Proxmox API token | — |
| | `--api-user` | Proxmox API user | `root@pam` |
| | `--no-auto-fix` | Disable auto-remediation | — |
| | `--validate-only` | Run pre-flight checks only | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

---

## Usage Examples

### Basic VM to LXC Conversion

```bash
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm
```

### Auto-Size + Auto-Start

```bash
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm --start
```

### Dry-Run Preview

```bash
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm --dry-run
```

### Preserve Network Configuration

```bash
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm --keep-network
```

### Unprivileged Container

```bash
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm --unprivileged --start
```

### Safe Conversion with Snapshot

```bash
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm \
  --snapshot --rollback-on-failure --start
```

### Batch Conversion from File

```bash
# Create conversions.txt:
# VMID CTID [storage] [disk-size]
cat > conversions.txt << 'EOF'
200 100 local-lvm 10G
201 101 local-lvm 15G
202 102
EOF

sudo ./vm-to-lxc.sh --batch conversions.txt
```

### Parallel Batch Processing

```bash
# Convert 4 VMs simultaneously
sudo ./vm-to-lxc.sh --batch conversions.txt --parallel 4
```

### Range Conversion

```bash
# Convert VMs 200-210 to CTs 100-110
sudo ./vm-to-lxc.sh --range 200-210:100-110 -s local-lvm
```

### Replace Existing Container

```bash
# Stop and destroy existing CT 100, then convert
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm --replace-ct --start
```

### Full Migration Workflow

```bash
# Migrate VM from cluster, convert, start
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm \
  --migrate-to-local --snapshot --destroy-source --start
```

### API Operations

```bash
# Use API for cluster operations
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm \
  --api-host proxmox-cluster.example.com \
  --api-token "root@pam!mytoken=xxxxx-xxxxx-xxxxx" \
  --migrate-to-local
```

### Wizard Mode

```bash
sudo ./vm-to-lxc.sh --wizard
```

---

## How It Works

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                    VM TO LXC CONVERSION PIPELINE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐          │
│  │  SOURCE  │───→│ VALIDATE │───→│ SNAPSHOT │───→│   STOP   │          │
│  │   VM     │    │   VMID   │    │  (opt)   │    │    VM    │          │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘          │
│       │                │               │               │               │
│       ↓                ↓               ↓               ↓               │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    CONVERSION PHASE                              │   │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐   │   │
│  │  │  DETECT  │───→│  MOUNT   │───→│   COPY   │───→│  CLEAN   │   │   │
│  │  │   DISK   │    │   DISK   │    │  RSYNC   │    │ ARTIFACT │   │   │
│  │  └──────────┘    └──────────┘    └──────────┘    └──────────┘   │   │
│  │       │               │              │              │          │   │
│  │       ↓               ↓              ↓              ↓          │   │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐                   │   │
│  │  │  NBD     │    │ ROOTFS   │    │ VM PKGS  │                   │   │
│  │  │  MODULE  │    │  DATA    │    │ KERNEL   │                   │   │
│  │  └──────────┘    └──────────┘    └──────────┘                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│       │                                                                │
│       ↓                                                                │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                         │
│  │  NETWORK │───→│  CREATE  │───→│   SET    │                         │
│  │   eth0   │    │    CT    │    │ PASSWORD │                         │
│  └──────────┘    └──────────┘    └──────────┘                         │
│       │                                                                │
│       ↓                                                                │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                         │
│  │  START   │    │ HEALTH   │    │ CLEANUP  │                         │
│  │    CT    │    │  CHECK   │    │  & DEST  │                         │
│  └──────────┘    └──────────┘    └──────────┘                         │
│       │                              │                                │
│       ↓                              ↓                                │
│  ┌──────────┐    ┌──────────┐                                         │
│  │   DONE   │    │ ROLLBACK │                                         │
│  │   🎉     │    │  (fail)  │                                         │
│  └──────────┘    └──────────┘                                         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Detailed Process

1. **Validation Phase**
   - Verify VM exists and is accessible
   - Check VM disk configuration (virtio0, scsi0, ide0, sata0)
   - Validate target storage availability
   - Check disk space requirements

2. **Snapshot Phase (Optional)**
   - Create VM snapshot for rollback safety
   - Store snapshot metadata

3. **VM Preparation**
   - Stop the VM for consistent copy
   - Ensure VM is fully powered off

4. **Disk Detection & Mounting**
   - Detect primary disk from VM config
   - Load NBD kernel module
   - Attach disk via qemu-nbd
   - Identify root partition
   - Mount filesystem

5. **Data Copy**
   - Use `rsync` to copy root filesystem
   - Preserve permissions and ownership
   - Handle special files
   - Progress reporting

6. **VM Artifact Cleanup**
   - Remove VM-specific packages:
     - `qemu-guest-agent`
     - `linux-image-*` kernels
     - `grub-pc`, `grub-efi-*`
     - `cloud-init` (optional)
   - Delete bootloader files from `/boot`
   - Remove initramfs images
   - Clean kernel modules

7. **Network Reconfiguration**
   - Detect VM network interface (usually `ens18`)
   - Reconfigure to LXC standard (`eth0`)
   - Update `/etc/network/interfaces` or netplan
   - Or preserve original with `--keep-network`

8. **Container Creation**
   - Create LXC container on target storage
   - Set root password (if provided)
   - Configure CPU, memory from VM
   - Set network bridge
   - Copy filesystem to container

9. **Health Checks**
   - Start container
   - Verify container boots
   - Check network connectivity
   - Validate DNS resolution

10. **Cleanup**
    - Unmount VM disk
    - Detach NBD device
    - Destroy source VM (if `--destroy-source`)

---

## Exit Codes

| Code | Name | Description |
| ---- | ---- | ----------- |
| `0` | `E_SUCCESS` | ✅ Success |
| `1` | `E_INVALID_ARG` | ❌ Invalid arguments |
| `2` | `E_NOT_FOUND` | ❌ VM/container/storage not found |
| `3` | `E_DISK_FULL` | ❌ Disk space issue |
| `4` | `E_PERMISSION` | ❌ Permission denied |
| `5` | `E_MIGRATION` | ❌ Cluster migration failed |
| `6` | `E_CONVERSION` | ❌ Core conversion failed |
| `7` | `E_DISK_MOUNT` | ❌ Failed to mount VM disk |
| `8` | `E_ARTIFACT_CLEANUP` | ❌ VM artifact cleanup failed |
| `9` | `E_NETWORK_CONFIG` | ❌ Network reconfiguration failed |
| `10` | `E_CT_CREATE` | ❌ Container creation failed |
| `11` | `E_PASSWORD_SET` | ❌ Failed to set root password |
| `12` | `E_HEALTH_CHECK` | ❌ Post-conversion health check failed |
| `13` | `E_HOOK_FAILED` | ❌ Hook execution failed |
| `14` | `E_SNAPSHOT_FAILED` | ❌ Snapshot creation failed |
| `15` | `E_ROLLBACK_FAILED` | ❌ Rollback failed |
| `16` | `E_NBD_MODULE` | ❌ NBD module not available |
| `100` | `E_BATCH_PARTIAL` | ⚠️ Batch had partial failures |
| `101` | `E_BATCH_ALL` | ❌ Batch completely failed |

---

## Post-Conversion

### Review Container Configuration

```bash
pct config 100
```

### Start the Container

```bash
pct start 100
```

### Enter Container Console

```bash
pct enter 100
```

### Verify Networking

Check `ip a` inside container — interface should be `eth0` (or preserved config if `--keep-network`).

### Clean Up VM-Specific Packages (Optional)

The script removes VM files automatically, but you may want to uninstall VM-specific packages:

**Debian/Ubuntu:**

```bash
apt purge -y grub-pc grub-efi-amd64 linux-image-* linux-headers-* qemu-guest-agent
apt autoremove -y
```

**Alpine:**

```bash
apk del grub linux-lts qemu-guest-agent
```

**RHEL/CentOS/Rocky:**

```bash
yum remove -y grub2 kernel kernel-core qemu-guest-agent
```

**Arch Linux:**

```bash
pacman -Rns grub linux qemu-guest-agent
```

### Remove Original VM

```bash
qm stop 200
qm destroy 200
```

---

## Troubleshooting

### Container Doesn't Start

**Check container config:**

```bash
pct config 100
```

**Check rootfs:**

```bash
pct config 100 | grep rootfs
```

**Check conversion log:**

```bash
cat /var/log/vm-to-lxc.log
```

### No Network in Container

**Verify container network:**

```bash
pct config 100 | grep net0
```

**Check interface inside container:**

```bash
pct exec 100 -- ip a
```

Should show `eth0`. If using `--keep-network`, the original VM interface name (`ens18`) may still be present — rename it or update the container config.

**Fix netplan (Ubuntu/Debian):**

```bash
pct exec 100 -- ls /etc/netplan/
pct exec 100 -- netplan apply
```

### VM Disk Not Detected

If the script can't find the VM disk:

```bash
# Check VM disk config
qm config 200 | grep -E '^(scsi|virtio|ide|sata)0:'

# Check disk path
pvesm path <volume-id>
```

### NBD Module Issues

```bash
# Check if nbd module is loaded
lsmod | grep nbd

# Load manually
modprobe nbd max_part=8

# Make persistent
echo "nbd" >> /etc/modules
```

### Permission Denied Errors

```bash
# Ensure running as root
whoami  # Should show 'root'

# Check script permissions
ls -la vm-to-lxc.sh  # Should be executable
```

---

## Related Documentation

- **[lxc-to-vm.sh](lxc-to-vm)** - Reverse conversion (LXC to VM)
- **[shrink-lxc.sh](shrink-lxc)** - Container optimization
- **[Hooks](Hooks)** - Custom automation hooks
- **[Troubleshooting](Troubleshooting)** - Common issues and fixes
