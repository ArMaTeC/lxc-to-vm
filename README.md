<div align="center">

# 🚀 Proxmox LXC to VM Converter

[![Release](https://img.shields.io/github/v/release/ArMaTeC/lxc-to-vm?style=for-the-badge&color=blue)](https://github.com/ArMaTeC/lxc-to-vm/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen.svg?style=for-the-badge)](.github/workflows/shellcheck.yml)

**Convert Proxmox LXC containers into fully bootable QEMU/KVM virtual machines** ⚡

[📖 Quick Start](#-quick-start) • [✨ Features](#-features) • [🛠️ Installation](#-installation) • [📚 Documentation](#-documentation)

</div>

---

## 📋 Table of Contents

- [✨ Features](#-features)
- [🐧 Supported Distributions](#-supported-distributions)
- [📦 Requirements](#-requirements)
- [🚀 Quick Start](#-quick-start)
- [🛠️ Installation](#-installation)
- [📖 Usage](#-usage)
- [🔧 Advanced Features](#-advanced-features)
- [🔄 Changelog](CHANGELOG.md)
- [🤝 Contributing](CONTRIBUTING.md)
- [📄 License](LICENSE)

---

## ✨ Features

### 🎯 Core Conversion (`lxc-to-vm.sh`)

| Feature | Description |
|---------|-------------|
| ⚡ **One-Command Conversion** | Convert any LXC container to a bootable VM instantly |
| 🐧 **Multi-Distro Support** | Debian, Ubuntu, Alpine, CentOS/RHEL/Rocky, Arch Linux (auto-detected) |
| 🔒 **BIOS & UEFI Boot** | MBR/SeaBIOS (default) or GPT/OVMF with `--bios ovmf` |
| 📉 **Integrated Disk Shrink** | `--shrink` shrinks LXC disk before conversion |
| 🔍 **Dry-Run Mode** | Preview every step without making changes |
| 🌐 **Network Preservation** | Keep original network config or use DHCP on `ens18` |
| ✅ **Auto-Start & Health Checks** | Boot VM and verify guest agent, IP, and reachability |
| 🛡️ **Snapshot & Rollback** | Automatic rollback on failure with `--rollback-on-failure` |
| 📊 **Batch Processing** | Convert multiple containers with `--batch` or `--range` |
| ⚡ **Parallel Execution** | Run N conversions concurrently with `--parallel` |
| 🧙 **Wizard Mode** | Interactive TUI with progress bars and guided setup |
| 💾 **Resume Capability** | Resume interrupted conversions from partial state |
| ☁️ **Cloud Export** | Export VM disks to S3, NFS, or SSH destinations |
| 📋 **Template Creation** | Convert directly to Proxmox VM templates |
| 🔌 **Plugin/Hook System** | Inject custom scripts at conversion stages |
| 📈 **Predictive Sizing** | AI-powered disk size recommendations |
| 🎨 **Colored Output** | Beautiful, color-coded progress messages |
| 📝 **Full Logging** | All operations logged to `/var/log/lxc-to-vm.log` |

### 💿 Disk Shrinker (`shrink-lxc.sh`)

| Feature | Description |
|---------|-------------|
| 📉 **Smart Shrinking** | Shrinks to actual usage + configurable headroom |
| 🔍 **Minimum Detection** | Queries `resize2fs -P` for true filesystem minimum |
| 🔄 **Auto-Retry** | Increments by 2GB and retries up to 5 times |
| 🗄️ **Multi-Backend** | LVM-thin, LVM, Directory (raw/qcow2), ZFS |
| 🔍 **Dry-Run Mode** | Preview the shrink plan safely |

---

## 🐧 Supported Distributions

| Distro Family | Detected IDs | Package Manager |
|---------------|--------------|-----------------|
| **🟣 Debian/Ubuntu** | `debian`, `ubuntu`, `linuxmint`, `pop`, `kali` | `apt` |
| **🔵 Alpine** | `alpine` | `apk` |
| **🔴 RHEL/CentOS** | `centos`, `rhel`, `rocky`, `alma`, `fedora` | `yum`/`dnf` |
| **⚫ Arch Linux** | `arch`, `manjaro`, `endeavouros` | `pacman` |

---

## 📦 Requirements

| Requirement | Details |
|-------------|---------|
| 🖥️ **Proxmox VE** | Version 7.x, 8.x, or 9.x |
| 📦 **Source LXC** | Debian, Ubuntu, Alpine, CentOS/RHEL/Rocky, or Arch based |
| 🔑 **Root Access** | Must run as `root` on Proxmox host |
| 💾 **Disk Space** | Filesystem space ≥ disk image size |
| 🌐 **Network** | Internet access (for kernel/GRUB installation) |

### 📋 Dependencies (Auto-Installed)

- `parted` — Disk partitioning
- `kpartx` — Partition mapping for loop devices
- `rsync` — Filesystem copy
- `e2fsprogs` — ext4 formatting and tools
- `dosfstools` — FAT32 formatting for UEFI ESP

---

## 🚀 Quick Start

### ⚡ Fastest Method — Shrink & Convert in One Command

```bash
# Download scripts
rm lxc-to-vm.sh shrink-lxc.sh
wget https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh
wget https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-lxc.sh
chmod +x lxc-to-vm.sh shrink-lxc.sh

# Convert with shrink and auto-start
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start
```

This shrinks the container disk to minimum safe size, converts it to a VM, and boots it — **all automatically**. No disk size needed! 🎉

### 📂 Clone the Repository

```bash
git clone https://github.com/ArMaTeC/lxc-to-vm.git
cd lxc-to-vm
chmod +x lxc-to-vm.sh shrink-lxc.sh
```

### 💬 Interactive Mode

```bash
sudo ./lxc-to-vm.sh
```

You'll be prompted for container ID, VM ID, storage, and disk size.

---

## 🛠️ Installation

No installation required! Just download and run. 🎉

### One-Liner Install

```bash
curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh -o lxc-to-vm.sh
curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-lxc.sh -o shrink-lxc.sh
chmod +x lxc-to-vm.sh shrink-lxc.sh
```

---

## 📖 Usage

### 🎯 Basic Conversion

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32
```

### 📉 Shrink + Convert (Recommended)

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start
```

Shrinks 200GB → ~31GB, converts, boots, and verifies — no disk size needed! 🚀

### 🔒 UEFI Boot with Auto-Start

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 -B ovmf --start
```

### 🔍 Dry-Run Preview

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --dry-run
```

### 🌐 Keep Existing Network Config

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --keep-network
```

### 📊 Batch Conversion

```bash
# Create conversions.txt with CTID VMID pairs
cat > conversions.txt << 'EOF'
100 200
101 201
105 205
EOF

sudo ./lxc-to-vm.sh --batch conversions.txt
```

### ⚡ Parallel Batch Processing

```bash
# Convert 4 containers simultaneously
sudo ./lxc-to-vm.sh --batch conversions.txt --parallel 4
```

---

## 🔧 Advanced Features

### 🧙 Wizard Mode

Launch an interactive TUI with progress bars and guided setup:

```bash
sudo ./lxc-to-vm.sh --wizard
```

### 💾 Snapshot & Rollback Safety

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --snapshot --rollback-on-failure --shrink --start
```

### 📋 VM Template Creation

```bash
# Create golden image template with sysprep
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --as-template --sysprep --snapshot
```

### ☁️ Cloud Export

```bash
# Export to AWS S3 after conversion
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --export-to s3://my-backup-bucket/vms/
```

### 🔄 Resume Interrupted Conversion

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 --resume
```

### 🗑️ Auto-Destroy Source Container

```bash
# Full migration: convert, verify, destroy original
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --shrink --start --destroy-source
```

### 📈 Predictive Disk Sizing

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --predict-size
```

---

## 📚 Documentation

### 📖 Command Reference

| Short | Long | Description | Default |
|-------|------|-------------|---------|
| `-c` | `--ctid` | Source LXC container ID | *(prompted)* |
| `-v` | `--vmid` | Target VM ID | *(prompted)* |
| `-s` | `--storage` | Proxmox storage name | *(prompted)* |
| `-d` | `--disk-size` | Disk size in GB | *(prompted or auto)* |
| `-f` | `--format` | Disk format (`qcow2`, `raw`, `vmdk`) | `qcow2` |
| `-b` | `--bridge` | Network bridge name | `vmbr0` |
| `-t` | `--temp-dir` | Working directory for temp disk | `/var/lib/vz/dump` |
| `-B` | `--bios` | Firmware (`seabios` or `ovmf`) | `seabios` |
| `-n` | `--dry-run` | Preview without changes | — |
| `-k` | `--keep-network` | Preserve original network config | — |
| `-S` | `--start` | Auto-start VM with health checks | — |
| | `--shrink` | Shrink LXC disk before converting | — |
| | `--snapshot` | Create LXC snapshot before conversion | — |
| | `--rollback-on-failure` | Auto-rollback on failure | — |
| | `--destroy-source` | Destroy original LXC after success | — |
| | `--resume` | Resume interrupted conversion | — |
| | `--parallel <N>` | Run N conversions in parallel | `1` |
| | `--validate-only` | Run pre-flight checks only | — |
| | `--export-to <DEST>` | Export VM disk (s3://, nfs://, ssh://) | — |
| | `--as-template` | Convert to VM template | — |
| | `--sysprep` | Clean template for cloning | — |
| | `--wizard` | Start interactive TUI wizard | — |
| | `--predict-size` | Use predictive disk sizing | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

### 🔄 How It Works

```
┌─────────────────────────────────────────────────┐
│  1️⃣ ARGUMENT PARSING & VALIDATION               │
│     Parse CLI flags or prompt interactively     │
├─────────────────────────────────────────────────┤
│  2️⃣ PRE-CONVERSION SHRINK (if --shrink)         │
│     Measure used space, shrink filesystem + LV    │
├─────────────────────────────────────────────────┤
│  3️⃣ DISK SPACE CHECK & WORKSPACE SELECTION      │
│     Auto-select mount point with enough room    │
├─────────────────────────────────────────────────┤
│  4️⃣ DISK CREATION                               │
│     MBR/BIOS or GPT/UEFI+ESP partitioning       │
├─────────────────────────────────────────────────┤
│  5️⃣ DATA COPY                                   │
│     rsync entire filesystem with progress bar     │
├─────────────────────────────────────────────────┤
│  6️⃣ BOOTLOADER INJECTION (CHROOT)               │
│     Auto-detect distro, install kernel + GRUB   │
├─────────────────────────────────────────────────┤
│  7️⃣ VM CREATION                                 │
│     Create VM, import disk, set boot order      │
├─────────────────────────────────────────────────┤
│  8️⃣ POST-CONVERSION VALIDATION                  │
│     6-point check: disk, boot, network, agent   │
├─────────────────────────────────────────────────┤
│  9️⃣ AUTO-START & HEALTH CHECK (if --start)      │
│     Boot VM, verify guest agent, ping test      │
└─────────────────────────────────────────────────┘
```

---

## 🎯 Exit Codes

### `lxc-to-vm.sh`

| Code | Meaning |
|------|---------|
| `0` | ✅ Success |
| `1` | ❌ Invalid arguments |
| `2` | ❌ Container/VM/storage not found |
| `3` | ❌ Disk space issue |
| `4` | ❌ Permission denied |
| `5` | ❌ Cluster migration failed |
| `6` | ❌ Core conversion failed |

### `shrink-lxc.sh`

| Code | Meaning |
|------|---------|
| `0` | ✅ Success |
| `1` | ❌ Invalid arguments |
| `2` | ❌ Container/resource not found |
| `3` | ❌ Disk space issue |
| `4` | ❌ Permission denied |
| `5` | ❌ Shrink workflow failed |

---

## 🤝 Support

If this project helps you, consider supporting development:

[![PayPal](https://img.shields.io/badge/PayPal-Donate-blue.svg?style=for-the-badge&logo=paypal)](https://www.paypal.com/paypalme/CityLifeRPG)

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<div align="center">

</div>

---

## 📝 Detailed Documentation

### 📁 Scripts Overview

This project includes two companion scripts:

| Script | Purpose | Version |
|--------|---------|---------|
| **`lxc-to-vm.sh`** | Converts LXC containers to bootable VMs | 6.0.4 |
| **`shrink-lxc.sh`** | Shrinks LXC disks before conversion | 6.0.4 |

---

## 🐧 Supported Distributions (Detailed)

| Distro Family | Detected IDs | Package Manager | Init System | Notes |
|---------------|--------------|-----------------|-------------|-------|
| **🟣 Debian/Ubuntu** | `debian`, `ubuntu`, `linuxmint`, `pop`, `kali` | `apt` | systemd | Primary target, most tested |
| **🔵 Alpine Linux** | `alpine` | `apk` | OpenRC | Auto-configured for containers |
| **🔴 RHEL/CentOS/Rocky** | `centos`, `rhel`, `rocky`, `alma`, `fedora` | `yum`/`dnf` | systemd | Enterprise-grade support |
| **⚫ Arch Linux** | `arch`, `manjaro`, `endeavouros` | `pacman` | systemd | Rolling release support |

The distribution is auto-detected from `/etc/os-release` inside the container. The script uses the appropriate package manager and bootloader installation commands for each family.

---

## 📋 Complete Requirements

### System Requirements

| Requirement | Details | Mandatory |
|-------------|---------|-----------|
| **Proxmox VE** | Version 7.x, 8.x, or 9.x | ✅ Yes |
| **Source LXC** | Debian, Ubuntu, Alpine, CentOS/RHEL/Rocky, or Arch based | ✅ Yes |
| **Root Access** | Must run as `root` on Proxmox host | ✅ Yes |
| **Disk Space** | Filesystem space ≥ disk image size | ✅ Yes |
| **Network** | Internet access for kernel/GRUB packages | ✅ Yes |
| **Architecture** | x86_64 (AMD64) only | ✅ Yes |

### Dependencies (Auto-Installed)

The following packages are automatically installed if missing:

- **`parted`** — Disk partitioning tool
- **`kpartx`** — Partition mapping for loop devices
- **`rsync`** — Fast filesystem copy with progress
- **`e2fsprogs`** — ext4 formatting and tools (`mkfs.ext4`, `resize2fs`, `e2fsck`)
- **`dosfstools`** — FAT32 formatting for UEFI ESP

---

## 🚀 Quick Start (Detailed)

### Method 1: Download and Run (Fastest)

```bash
# Remove old versions (if any)
rm -f lxc-to-vm.sh shrink-lxc.sh

# Download latest versions
wget https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh
wget https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-lxc.sh

# Make executable
chmod +x lxc-to-vm.sh shrink-lxc.sh

# Run with shrink and auto-start
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start
```

This shrinks the container disk to minimum safe size, converts it to a VM, and boots it — **all automatically**. No disk size needed!

### Method 2: Clone the Repository

```bash
git clone https://github.com/ArMaTeC/lxc-to-vm.git
cd lxc-to-vm
chmod +x lxc-to-vm.sh shrink-lxc.sh
sudo ./lxc-to-vm.sh
```

### Method 3: Interactive Mode

```bash
sudo ./lxc-to-vm.sh
```

You'll be prompted for:
- Source Container ID (e.g., 100)
- Target VM ID (e.g., 200)
- Storage name (e.g., local-lvm)
- Disk size in GB (optional with `--shrink`)

---

## 🛠️ Installation Options

### One-Liner Install

```bash
curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh -o lxc-to-vm.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-lxc.sh -o shrink-lxc.sh \
  && chmod +x lxc-to-vm.sh shrink-lxc.sh
```

### System-Wide Installation (Optional)

```bash
# Copy to system path
sudo cp lxc-to-vm.sh /usr/local/bin/lxc-to-vm
sudo cp shrink-lxc.sh /usr/local/bin/shrink-lxc
sudo chmod +x /usr/local/bin/lxc-to-vm /usr/local/bin/shrink-lxc

# Now run from anywhere
sudo lxc-to-vm -c 100 -v 200 -s local-lvm
```

---

## 📖 Complete Usage Guide

### 🔧 lxc-to-vm.sh — Main Converter

#### Basic Conversion (Non-Interactive)

```bash
sudo ./lxc-to-vm.sh -c <CTID> -v <VMID> -s <storage> -d <disk_size>
```

Example:
```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32
```

#### Interactive Mode

```bash
sudo ./lxc-to-vm.sh
```

Sample output:
```
==========================================
   PROXMOX LXC TO VM CONVERTER v6.0.4
==========================================
Enter Source Container ID (e.g., 100): 100
Enter New VM ID (e.g., 200): 200
Enter Target Storage Name (e.g., local-lvm): local-lvm
Enter Disk Size in GB (must be > used space, e.g., 32): 32
```

#### Shrink + Convert (Recommended)

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start
```

Benefits:
- Automatically shrinks 200GB → ~31GB
- No need to specify disk size
- Faster conversion
- Boots and verifies automatically

#### UEFI Boot Mode

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 -B ovmf --start
```

Creates GPT partition with 512MB EFI System Partition.

#### Dry-Run Preview

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --dry-run
```

Shows full summary without making changes:
- Source/target config
- LXC memory/cores
- Disk space check
- Step-by-step plan

#### Keep Network Configuration

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --keep-network
```

Preserves original network config, translating `eth0` → `ens18`.

#### Batch Conversion

Create `conversions.txt`:
```
# Format: <CTID> <VMID> [storage] [disk_size]
100 200 local-lvm 32
101 201 local-lvm 32
102 202 local-lvm 32
```

Run batch:
```bash
sudo ./lxc-to-vm.sh --batch conversions.txt
```

#### Parallel Batch Processing

```bash
# Convert 4 containers simultaneously
sudo ./lxc-to-vm.sh --batch conversions.txt --parallel 4
```

---

### 📉 shrink-lxc.sh — Disk Shrinker

#### Basic Shrink

```bash
sudo ./shrink-lxc.sh -c 100
```

Shrinks to usage + 1GB headroom (default).

#### With Custom Headroom

```bash
sudo ./shrink-lxc.sh -c 100 -g 2
```

Adds 2GB headroom instead of 1GB.

#### Dry-Run Preview

```bash
sudo ./shrink-lxc.sh -c 100 --dry-run
```

Shows shrink plan without executing.

#### How It Works

1. Stops container (restarts after if running)
2. Mounts rootfs, calculates actual used space
3. Queries true minimum filesystem size via `resize2fs -P`
4. Adds metadata margin (5% or 512MB min) + headroom
5. Runs `e2fsck` → `resize2fs` → shrinks LV/image/ZFS
6. Auto-retries with +2GB increments if needed (up to 5x)
7. Updates container config with new size

**Supported Backends:**
- **LVM / LVM-thin**: `resize2fs` + `lvresize`
- **Directory (raw)**: `resize2fs` via losetup + `truncate`
- **Directory (qcow2)**: Convert → shrink → convert back
- **ZFS**: `resize2fs` + `zfs set volsize`

---

## 🔬 Feature Deep Dives

### 🧙 Wizard Mode (`--wizard`)

Interactive TUI with progress bars:

```bash
sudo ./lxc-to-vm.sh --wizard
```

Guides through:
1. Source container selection
2. Target VM ID
3. Storage selection
4. Shrink and disk size options
5. UEFI/BIOS selection
6. Network configuration
7. Snapshot and rollback preferences
8. Auto-start and cleanup options

### 💾 Snapshot & Rollback (`--snapshot`, `--rollback-on-failure`)

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --snapshot --rollback-on-failure --shrink
```

- Creates snapshot `pre-conversion-<timestamp>` before changes
- Automatically restores if conversion fails
- Snapshot removed on successful completion

Manual rollback if needed:
```bash
pct rollback 100 pre-conversion-20250211-143022
```

### 📋 Configuration Profiles (`--save-profile`, `--profile`)

Save common settings:

```bash
# Save profile
sudo ./lxc-to-vm.sh -s local-lvm -B ovmf --keep-network --save-profile webserver

# List profiles
sudo ./lxc-to-vm.sh --list-profiles

# Use profile
sudo ./lxc-to-vm.sh -c 100 -v 200 --profile webserver

# Override profile settings
sudo ./lxc-to-vm.sh -c 100 -v 200 --profile webserver -b vmbr1
```

Profiles stored in `/var/lib/lxc-to-vm/profiles/`.

### 🔄 Resume Capability (`--resume`)

Resume interrupted conversions:

```bash
# Start conversion
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 200

# If interrupted, resume
sudo ./lxc-to-vm.sh -c 100 -v 200 --resume
```

Resume includes:
- Partial rsync data
- Conversion stage tracking
- Timestamp of last attempt

### 🗑️ Auto-Destroy Source (`--destroy-source`)

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --shrink --start --destroy-source
```

**⚠️ Warning:** Only use after testing VM works. Combine with `--snapshot` for safety.

Full safe migration:
```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --snapshot --rollback-on-failure --shrink --start --destroy-source
```

### 📊 Pre-Flight Validation (`--validate-only`)

Check readiness without converting:

```bash
sudo ./lxc-to-vm.sh -c 100 --validate-only
```

Checks:
- Container exists and is accessible
- Container state (stopped/running)
- Distro detection and compatibility
- Root filesystem type
- Network configuration
- Storage availability
- Required dependencies

Output includes readiness score and recommendations.

### ☁️ Cloud/Remote Export (`--export-to`)

Export VM disk after conversion:

```bash
# Export to S3
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --export-to s3://my-backup-bucket/vms/

# Export to NFS
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --export-to nfs://nas-server/backup/

# Export via SSH
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --export-to ssh://backup-server:/storage/vms/
```

### 📋 VM Template Creation (`--as-template`, `--sysprep`)

Create golden images:

```bash
# Create template
sudo ./lxc-to-vm.sh -c 100 -v 900 -s local-lvm --as-template

# Template with sysprep for cloning
sudo ./lxc-to-vm.sh -c 100 -v 900 -s local-lvm --as-template --sysprep
```

**Sysprep cleans:**
- SSH host keys
- Machine ID
- Persistent network rules
- Logs
- Temp files

---

## 🔄 How It Works (Technical)

```
┌─────────────────────────────────────────────────┐
│  1️⃣ ARGUMENT PARSING & VALIDATION               │
│     Parse CLI flags or prompt interactively     │
│     Validate IDs, storage, format, BIOS type     │
├─────────────────────────────────────────────────┤
│  2️⃣ PRE-CONVERSION SHRINK (if --shrink)         │
│     Measure used space, shrink filesystem + LV  │
│     Auto-set disk size from shrunk container    │
├─────────────────────────────────────────────────┤
│  3️⃣ DISK SPACE CHECK & WORKSPACE SELECTION      │
│     Auto-select mount point with enough room     │
│     Explain LVM/ZFS vs filesystem constraints    │
├─────────────────────────────────────────────────┤
│  4️⃣ DISK CREATION                               │
│     MBR/BIOS or GPT/UEFI+ESP partitioning       │
│     Format ext4 (+ FAT32 ESP for UEFI)          │
├─────────────────────────────────────────────────┤
│  5️⃣ DATA COPY                                   │
│     Mount LXC rootfs via pct mount             │
│     rsync entire filesystem with progress bar   │
├─────────────────────────────────────────────────┤
│  6️⃣ BOOTLOADER INJECTION (CHROOT)               │
│     Auto-detect distro (apt/apk/yum/pacman)     │
│     Write /etc/fstab, configure networking      │
│     Install kernel + GRUB (BIOS or EFI)         │
├─────────────────────────────────────────────────┤
│  7️⃣ VM CREATION                                 │
│     Create VM (qm create), import disk          │
│     Add EFI disk for UEFI. Set boot order       │
├─────────────────────────────────────────────────┤
│  8️⃣ POST-CONVERSION VALIDATION                  │
│     6-point check: disk, boot, network, agent   │
├─────────────────────────────────────────────────┤
│  9️⃣ AUTO-START & HEALTH CHECK (if --start)     │
│     Boot VM, wait for guest agent, verify IP    │
└─────────────────────────────────────────────────┘
```

---

## 🎯 Complete Command Reference

### lxc-to-vm.sh Options

| Short | Long | Description | Default |
|-------|------|-------------|---------|
| `-c` | `--ctid` | Source LXC container ID | Prompted |
| `-v` | `--vmid` | Target VM ID | Prompted |
| `-s` | `--storage` | Proxmox storage name | Prompted |
| `-d` | `--disk-size` | Disk size in GB | Prompted or auto |
| `-f` | `--format` | Disk format (`qcow2`, `raw`, `vmdk`) | `qcow2` |
| `-b` | `--bridge` | Network bridge name | `vmbr0` |
| `-t` | `--temp-dir` | Working directory for temp disk | `/var/lib/vz/dump` |
| `-B` | `--bios` | Firmware (`seabios`, `ovmf`) | `seabios` |
| `-n` | `--dry-run` | Preview without changes | — |
| `-k` | `--keep-network` | Preserve original network config | — |
| `-S` | `--start` | Auto-start VM with health checks | — |
| | `--shrink` | Shrink LXC disk before converting | — |
| | `--snapshot` | Create LXC snapshot before conversion | — |
| | `--rollback-on-failure` | Auto-rollback on failure | — |
| | `--destroy-source` | Destroy original LXC after success | — |
| | `--resume` | Resume interrupted conversion | — |
| | `--parallel <N>` | Run N conversions in parallel | `1` |
| | `--validate-only` | Run pre-flight checks only | — |
| | `--export-to <DEST>` | Export VM disk (s3://, nfs://, ssh://) | — |
| | `--as-template` | Convert to VM template | — |
| | `--sysprep` | Clean template for cloning | — |
| | `--wizard` | Start interactive TUI wizard | — |
| | `--save-profile <NAME>` | Save options as named profile | — |
| | `--profile <NAME>` | Load options from saved profile | — |
| | `--list-profiles` | List all saved profiles | — |
| | `--predict-size` | Use predictive disk sizing | — |
| | `--batch <FILE>` | Batch conversion from file | — |
| | `--range <SPEC>` | Range conversion (e.g., 100-110:200-210) | — |
| | `--migrate-to-local` | Migrate container to local node | — |
| | `--api-host <HOST>` | Proxmox API host | — |
| | `--api-token <TOKEN>` | Proxmox API token | — |
| | `--api-user <USER>` | Proxmox API user | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

### shrink-lxc.sh Options

| Short | Long | Description | Default |
|-------|------|-------------|---------|
| `-c` | `--ctid` | Container ID to shrink | Prompted |
| `-g` | `--headroom` | Extra headroom in GB | `1` |
| `-n` | `--dry-run` | Preview without making changes | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

---

## 🎯 Exit Codes (Detailed)

### lxc-to-vm.sh

| Code | Name | Meaning |
|------|------|---------|
| `0` | `E_SUCCESS` | ✅ Success |
| `1` | `E_INVALID_ARG` | ❌ Invalid arguments |
| `2` | `E_NOT_FOUND` | ❌ Container/VM/storage not found |
| `3` | `E_DISK_FULL` | ❌ Disk space issue |
| `4` | `E_PERMISSION` | ❌ Permission denied |
| `5` | `E_MIGRATION` | ❌ Cluster migration failed |
| `6` | `E_CONVERSION` | ❌ Core conversion failed |

### shrink-lxc.sh

| Code | Name | Meaning |
|------|------|---------|
| `0` | `E_SUCCESS` | ✅ Success |
| `1` | `E_INVALID_ARG` | ❌ Invalid arguments |
| `2` | `E_NOT_FOUND` | ❌ Container/resource not found |
| `3` | `E_DISK_FULL` | ❌ Disk space issue |
| `4` | `E_PERMISSION` | ❌ Permission denied |
| `5` | `E_SHRINK_FAILED` | ❌ Shrink workflow failed |

---

## 🔧 Post-Conversion Steps

After the script completes (if you didn't use `--start`):

### 1. Review VM Configuration
```bash
qm config <VMID>
```

### 2. Start the VM
```bash
qm start <VMID>
```

### 3. Access Console
```bash
qm terminal <VMID> -iface serial0
```

### 4. Verify Networking
Check `ip a` inside VM — interface should be `ens18` (or preserved config if `--keep-network`).

### 5. Install QEMU Guest Agent (if missing)

**Debian/Ubuntu:**
```bash
apt update && apt install qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

**Alpine:**
```bash
apk add qemu-guest-agent
rc-update add qemu-guest-agent
rc-service qemu-guest-agent start
```

**RHEL/CentOS/Rocky:**
```bash
yum install qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

**Arch Linux:**
```bash
pacman -S qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

### 6. Remove Original LXC (after verifying VM works)
```bash
pct destroy <CTID>
```

---

## 🐛 Troubleshooting

### VM Doesn't Boot

**Check boot order:**
```bash
qm config <VMID> | grep boot
```
Ensure `scsi0` is first.

**Check disk attachment:**
```bash
qm config <VMID> | grep scsi0
```

**UEFI issues:**
```bash
qm config <VMID> | grep efidisk
```
For `--bios ovmf`, `efidisk0` must exist.

**Check conversion log:**
```bash
cat /var/log/lxc-to-vm.log
```

### No Network in VM

**Verify NIC configuration:**
```bash
qm config <VMID> | grep net0
```

**Check interface inside VM:**
```bash
ip a
```
Should show `ens18`.

**Netplan systems:**
```bash
ls /etc/netplan/
netplan apply
```

**Traditional interfaces:**
```bash
cat /etc/network/interfaces
```

### Container Not Found
```bash
pct list
```

### Storage Not Found
```bash
pvesm status
```

### Disk Space Issues

**LVM/ZFS vs Filesystem:**
- LVM/ZFS pools ≠ filesystem space
- Temp image needs *filesystem* space
- Use `--shrink` to reduce required space
- Use `--temp-dir` for alternative path:
  ```bash
  sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 200 -t /mnt/scratch
  ```

### Shrink Fails

**Check shrink log:**
```bash
cat /var/log/shrink-lxc.log
```

**Manual retry with more headroom:**
```bash
sudo ./shrink-lxc.sh -c 100 -g 5
```

**Ensure container is stopped:**
```bash
pct stop 100
```

### Exit Code Handling in Automation

```bash
./lxc-to-vm.sh -c 126 -v 260 -s local-lvm -d 6
rc=$?

case "$rc" in
  2) echo "Missing resource (CT/VM/storage)" ;;
  3) echo "Disk space issue" ;;
  5) echo "Migration failure" ;;
  6) echo "Conversion failure - check /var/log/lxc-to-vm.log" ;;
  0) echo "Success" ;;
  *) echo "General failure (code $rc)" ;;
esac
```

---

## ⚠️ Limitations

- **Single-disk containers only** — Multi-mount-point LXC configs not handled
- **No ZFS-to-ZFS native** — Disk created as raw image and imported
- **Proxmox host only** — Must run directly on Proxmox VE node
- **x86_64 only** — ARM containers not supported
- **ext4 filesystems** — XFS, btrfs not supported for shrink/conversion

---

## 🤝 Contributing

Contributions welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

1. Fork the repository
2. Create feature branch: `git checkout -b feature/my-feature`
3. Commit changes: `git commit -m 'Add my feature'`
4. Push to branch: `git push origin feature/my-feature`
5. Open Pull Request

---

## 📄 License

This project is licensed under the **MIT License** — see [LICENSE](LICENSE) for details.

---

<div align="center">

**[⬆ Back to Top](#-proxmox-lxc-to-vm-converter)**

Made with ❤️ by [ArMaTeC](https://github.com/ArMaTeC)

</div>
