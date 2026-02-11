# Proxmox LXC to VM Converter

[![Release](https://github.com/ArMaTeC/lxc-to-vm/actions/workflows/release.yml/badge.svg)](https://github.com/ArMaTeC/lxc-to-vm/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A robust Bash toolkit that converts **Proxmox LXC containers** into fully bootable **QEMU/KVM virtual machines** — directly on your Proxmox VE host. Includes a companion disk-shrink script and handles disk creation, filesystem copy, kernel/GRUB installation, networking reconfiguration, and VM provisioning automatically.

---

## Table of Contents

- [Scripts](#scripts)
- [Features](#features)
- [Supported Distros](#supported-distros)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [lxc-to-vm.sh — Converter](#lxc-to-vmsh--converter)
  - [Interactive Mode](#interactive-mode)
  - [Non-Interactive Mode](#non-interactive-mode)
  - [Options Reference](#lxc-to-vm-options)
  - [How It Works](#how-it-works)
  - [Conversion Examples](#conversion-examples)
- [shrink-lxc.sh — Disk Shrinker](#shrink-lxcsh--disk-shrinker)
  - [Why Shrink?](#why-shrink)
  - [Shrink Options](#shrink-options)
  - [Shrink Examples](#shrink-examples)
  - [How Shrink Works](#how-shrink-works)
- [Feature Deep Dives](#feature-deep-dives)
  - [--shrink (Integrated Shrink + Convert)](#--shrink-integrated-shrink--convert)
  - [--dry-run (Preview Mode)](#--dry-run-preview-mode)
  - [--bios ovmf (UEFI Boot)](#--bios-ovmf-uefi-boot)
  - [--keep-network (Network Preservation)](#--keep-network-network-preservation)
  - [--start (Auto-Start & Health Checks)](#--start-auto-start--health-checks)
  - [Batch & Range Conversion](#batch--range-conversion)
  - [Snapshot & Rollback](#snapshot--rollback)
  - [Configuration Profiles](#configuration-profiles)
  - [Resume Capability](#resume-capability)
  - [Auto-Destroy Source](#auto-destroy-source)
- [v6.0.0 Feature Deep Dives](#v600-feature-deep-dives)
  - [Wizard Mode (--wizard)](#wizard-mode---wizard)
  - [Parallel Batch Processing (--parallel)](#parallel-batch-processing---parallel)
  - [Pre-Flight Validation (--validate-only)](#pre-flight-validation---validate-only)
  - [Cloud/Remote Storage Export (--export-to)](#cloudremote-storage-export---export-to)
  - [VM Template Creation (--as-template)](#vm-template-creation---as-template)
- [Disk Space Management](#disk-space-management)
  - [Post-Conversion Validation](#post-conversion-validation)
- [Post-Conversion Steps](#post-conversion-steps)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Contributing](#contributing)
- [License](#license)

---

## Scripts

This project includes two scripts:

| Script | Purpose |
|---|---|
| **`lxc-to-vm.sh`** | Converts an LXC container into a bootable VM. Main script. |
| **`shrink-lxc.sh`** | Shrinks an LXC container's disk to used space + headroom. Standalone or use `--shrink` in `lxc-to-vm.sh`. |

---

## Features

### Conversion (`lxc-to-vm.sh`)

- **One-command conversion** — turn any LXC into a bootable VM
- **Multi-distro support** — Debian, Ubuntu, Alpine, CentOS/RHEL/Rocky, Arch Linux (auto-detected)
- **BIOS & UEFI boot** — MBR/SeaBIOS (default) or GPT/OVMF with `--bios ovmf`
- **Integrated disk shrink** — `--shrink` shrinks the LXC disk before conversion, auto-sets disk size
- **Dry-run mode** — preview every step without making changes (`--dry-run`)
- **Network preservation** — keep original network config with `--keep-network`, or replace with DHCP on `ens18`
- **Auto-start & health checks** — boot the VM and verify guest agent, IP, and reachability (`--start`)
- **Post-conversion validation** — automatic 6-point check (disk, boot order, network, agent, EFI)
- **Interactive & non-interactive modes** — use CLI flags for scripting or answer prompts manually
- **Auto-dependency installation** — missing tools (`parted`, `kpartx`, `rsync`, etc.) installed automatically
- **Input & storage validation** — catches invalid IDs, missing storage, format errors before work begins
- **Smart disk space management** — checks available space, auto-selects mount points with room, explains LVM vs filesystem constraints
- **Custom working directory** — `--temp-dir` to place the temporary disk image on any mount point
- **LXC config inheritance** — memory, CPU cores pulled from the source container config
- **Serial console support** — enables `ttyS0` serial console for Proxmox terminal access
- **Colored output** — color-coded progress messages (auto-disabled when piped)
- **Full logging** — all operations logged to `/var/log/lxc-to-vm.log`
- **Safe cleanup** — trap-based cleanup removes temp files and loop devices on exit or error
- **Wizard mode** — interactive TUI with progress bars and guided setup (`--wizard`)
- **Parallel batch processing** — run N conversions concurrently (`--parallel N`)
- **Pre-flight validation** — comprehensive checks without converting (`--validate-only`)
- **Cloud/remote export** — export VM disks to S3, NFS, or SSH destinations (`--export-to`)
- **VM template creation** — convert to Proxmox template with optional sysprep (`--as-template`)
- **Auto-rollback** — automatically restore container if conversion fails (`--rollback-on-failure`)
- **Configuration profiles** — save and reuse common conversion settings (`--save-profile`, `--profile`)
- **Resume capability** — resume interrupted conversions from partial state (`--resume`)
- **Auto-cleanup** — destroy original LXC after successful conversion (`--destroy-source`)

### Disk Shrinker (`shrink-lxc.sh`)

- **Shrinks LXC disks** to actual usage + configurable headroom
- **Smart minimum detection** — queries `resize2fs -P` for the true filesystem minimum size
- **Auto-retry** — if resize2fs fails, automatically increments by 2GB and retries (up to 5 attempts)
- **Multi-backend** — supports LVM-thin, LVM, directory (raw/qcow2), and ZFS storage
- **Dry-run mode** — preview the shrink plan without making changes
- **Safety confirmation** — prompts before destructive operations
- **Prints ready-to-use conversion command** after shrinking

---

## Supported Distros

| Distro Family | Detected IDs | Package Manager | Notes |
|---|---|---|---|
| **Debian/Ubuntu** | `debian`, `ubuntu`, `linuxmint`, `pop`, `kali` | `apt` | Primary target, most tested |
| **Alpine** | `alpine` | `apk` | OpenRC init system configured automatically |
| **RHEL/CentOS** | `centos`, `rhel`, `rocky`, `alma`, `fedora` | `yum`/`dnf` | Kernel + GRUB2 |
| **Arch Linux** | `arch`, `manjaro`, `endeavouros` | `pacman` | Kernel + GRUB |

Distro is auto-detected from `/etc/os-release` inside the container. The script uses the appropriate package manager and bootloader installation commands for each family.

---

## Requirements

| Requirement | Details |
|---|---|
| **Proxmox VE** | Version 7.x or 8.x |
| **Source LXC** | Debian, Ubuntu, Alpine, CentOS/RHEL/Rocky, or Arch based container |
| **Root access** | Scripts must run as `root` on the Proxmox host |
| **Free disk space** | Filesystem space ≥ disk image size (LVM/ZFS storage cannot be used as temp space — see [Disk Space Management](#disk-space-management)) |
| **Network** | Internet access (to install kernel/GRUB packages inside chroot) |

### Dependencies (auto-installed by `lxc-to-vm.sh`)

- `parted` — disk partitioning
- `kpartx` — partition mapping for loop devices
- `rsync` — filesystem copy
- `e2fsprogs` — ext4 formatting and filesystem tools (`mkfs.ext4`, `resize2fs`, `e2fsck`)
- `dosfstools` — FAT32 formatting for UEFI ESP (only when using `--bios ovmf`)

---

## Quick Start

### Fastest method — shrink and convert in one command

```bash
wget https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh
chmod +x lxc-to-vm.sh
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start
```

This shrinks the container disk to the minimum safe size, converts it to a VM, and boots it — all automatically. No need to specify disk size.

### Clone the repository

```bash
git clone https://github.com/ArMaTeC/lxc-to-vm.git
cd lxc-to-vm
chmod +x lxc-to-vm.sh shrink-lxc.sh
```

### Interactive mode

```bash
sudo ./lxc-to-vm.sh
```

You'll be prompted for container ID, VM ID, storage, and disk size.

---

## lxc-to-vm.sh — Converter

### Interactive Mode

Run without arguments to be prompted for each value:

```bash
sudo ./lxc-to-vm.sh
```

```
==========================================
   PROXMOX LXC TO VM CONVERTER v6.0.0
==========================================
Enter Source Container ID (e.g., 100): 100
Enter New VM ID (e.g., 200): 200
Enter Target Storage Name (e.g., local-lvm): local-lvm
Enter Disk Size in GB (must be > used space, e.g., 32): 32
```

> **Note:** When using `--shrink`, the disk size prompt is skipped — the size is auto-calculated from the container's actual usage.

### Non-Interactive Mode

Pass all required values as flags — ideal for automation:

```bash
sudo ./lxc-to-vm.sh \
    --ctid 100 \
    --vmid 200 \
    --storage local-lvm \
    --disk-size 32
```

With all options:

```bash
sudo ./lxc-to-vm.sh \
    -c 100 \
    -v 200 \
    -s local-lvm \
    -d 32 \
    -f qcow2 \
    -b vmbr0 \
    -t /mnt/scratch \
    -B ovmf \
    --keep-network \
    --shrink \
    --start
```

### lxc-to-vm Options

| Short | Long | Description | Default |
|---|---|---|---|
| `-c` | `--ctid` | Source LXC container ID | *(prompted)* |
| `-v` | `--vmid` | Target VM ID | *(prompted)* |
| `-s` | `--storage` | Proxmox storage name | *(prompted)* |
| `-d` | `--disk-size` | Disk size in GB | *(prompted or auto via `--shrink`)* |
| `-f` | `--format` | Disk image format (`qcow2`, `raw`, `vmdk`) | `qcow2` |
| `-b` | `--bridge` | Network bridge name | `vmbr0` |
| `-t` | `--temp-dir` | Working directory for the temp disk image | `/var/lib/vz/dump` |
| `-B` | `--bios` | Firmware type (`seabios` or `ovmf` for UEFI) | `seabios` |
| `-n` | `--dry-run` | Preview what would happen without making changes | — |
| `-k` | `--keep-network` | Preserve original network config (translate eth0→ens18) | — |
| `-S` | `--start` | Auto-start VM after conversion and run health checks | — |
| | `--shrink` | Shrink LXC disk to usage + headroom before converting (skips disk size prompt) | — |
| | `--snapshot` | Create LXC snapshot before conversion for rollback safety | — |
| | `--rollback-on-failure` | Auto-rollback to snapshot if conversion fails | — |
| | `--destroy-source` | Destroy original LXC after successful conversion | — |
| | `--resume` | Resume interrupted conversion from partial state | — |
| | `--parallel <N>` | Run N conversions in parallel (batch mode) | `1` |
| | `--validate-only` | Run pre-flight checks without converting | — |
| | `--export-to <DEST>` | Export VM disk after conversion (s3://, nfs://, ssh://) | — |
| | `--as-template` | Convert to VM template instead of regular VM | — |
| | `--sysprep` | Clean template for cloning (remove SSH keys, machine-id) | — |
| | `--wizard` | Start interactive TUI wizard with progress bars | — |
| | `--save-profile <NAME>` | Save current options as a named profile | — |
| | `--profile <NAME>` | Load options from a saved profile | — |
| | `--list-profiles` | List all saved profiles | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

### How It Works

```
┌─────────────────────────────────────────────────┐
│  1. ARGUMENT PARSING & VALIDATION               │
│     Parse CLI flags or prompt interactively.     │
│     Validate IDs, storage, format, BIOS type.    │
├─────────────────────────────────────────────────┤
│  2. PRE-CONVERSION SHRINK (if --shrink)         │
│     Measure used space, shrink filesystem + LV.  │
│     Auto-set disk size from shrunk container.    │
├─────────────────────────────────────────────────┤
│  3. DISK SPACE CHECK & WORKSPACE SELECTION      │
│     Auto-select mount point with enough room.    │
│     Explain LVM/ZFS vs filesystem constraints.   │
├─────────────────────────────────────────────────┤
│  4. DISK CREATION                               │
│     MBR/BIOS or GPT/UEFI+ESP partitioning.      │
│     Format ext4 (+ FAT32 ESP for UEFI).         │
├─────────────────────────────────────────────────┤
│  5. DATA COPY                                   │
│     Mount LXC rootfs via pct mount.              │
│     rsync entire filesystem with progress bar.   │
├─────────────────────────────────────────────────┤
│  6. BOOTLOADER INJECTION (CHROOT)               │
│     Auto-detect distro (apt/apk/yum/pacman).    │
│     Write /etc/fstab, configure networking.      │
│     Install kernel + GRUB (BIOS or EFI).        │
├─────────────────────────────────────────────────┤
│  7. VM CREATION                                 │
│     Create VM (qm create), import disk.         │
│     Add EFI disk for UEFI. Set boot order.      │
├─────────────────────────────────────────────────┤
│  8. POST-CONVERSION VALIDATION                  │
│     6-point check: disk, boot, network, agent.  │
├─────────────────────────────────────────────────┤
│  9. AUTO-START & HEALTH CHECK (if --start)      │
│     Boot VM, wait for guest agent, verify IP.    │
└─────────────────────────────────────────────────┘
```

### Conversion Examples

**Basic conversion:**
```bash
sudo ./lxc-to-vm.sh -c 105 -v 300 -s local-lvm -d 20
```

**Shrink + convert (recommended for large containers):**
```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start
# Shrinks 200GB → ~31GB, converts, boots, and verifies — no disk size needed
```

**UEFI boot with auto-start:**
```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 -B ovmf --start
```

**Dry-run preview:**
```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --dry-run
```

**Keep existing network config:**
```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --keep-network
```

**Raw disk format on a specific bridge:**
```bash
sudo ./lxc-to-vm.sh -c 105 -v 300 -s local-lvm -d 20 -f raw -b vmbr1
```

**Large container with alternative temp directory:**
```bash
sudo ./lxc-to-vm.sh -c 127 -v 300 -s local-lvm -d 201 -f raw -t /mnt/bigdisk
```

**Alpine LXC (distro auto-detected):**
```bash
sudo ./lxc-to-vm.sh -c 110 -v 210 -s local-lvm -d 10
```

**Create golden image template:**
```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --as-template --sysprep
```

**Wizard mode (interactive TUI):**
```bash
sudo ./lxc-to-vm.sh --wizard
```

**Everything at once:**
```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -B ovmf --shrink --keep-network --start
```

**Batch conversion:**
```bash
# Create conversions.txt with CTID VMID pairs
cat > conversions.txt << 'EOF'
100 200
101 201
105 205
EOF

sudo ./lxc-to-vm.sh --batch conversions.txt
```

**Range conversion:**
```bash
sudo ./lxc-to-vm.sh --range 100-110:200-210 -s local-lvm --shrink
```

**Full migration with safety and cleanup:**
```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --snapshot --rollback-on-failure --shrink --start --destroy-source
```

---

## shrink-lxc.sh — Disk Shrinker

A standalone script to shrink an LXC container's root disk to its actual used space plus configurable headroom.

### Why Shrink?

- **Save temp disk space** — the converter needs filesystem space equal to the disk size for a temporary raw image. A 200GB container using only 27GB would need 200GB of temp space without shrinking.
- **Faster conversion** — smaller disk = faster rsync copy and disk import.
- **Reclaim LVM/ZFS space** — free up storage pool space occupied by unused allocation.

### Shrink Options

| Short | Long | Description | Default |
|---|---|---|---|
| `-c` | `--ctid` | Container ID to shrink | *(prompted)* |
| `-g` | `--headroom` | Extra headroom in GB above used space | `1` |
| `-n` | `--dry-run` | Show what would be done without making changes | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

### Shrink Examples

```bash
# Shrink CT 100 to usage + 1GB
sudo ./shrink-lxc.sh -c 100

# Preview the shrink plan
sudo ./shrink-lxc.sh -c 100 --dry-run

# More headroom (2GB extra)
sudo ./shrink-lxc.sh -c 100 -g 2
```

After completion, the script prints a ready-to-use conversion command:

```
==========================================
          SHRINK COMPLETE
==========================================
  Container:    100
  Storage:      local-lvm (lvmthin)
  Previous:     200GB
  New size:     31GB
  Saved:        169GB
  Used space:   27GiB

  Ready to convert:
    ./lxc-to-vm.sh -c 100 -d 31 -s local-lvm
```

### How Shrink Works

| Step | Action |
|---|---|
| **1** | Stop the container (restarts after if it was running) |
| **2** | Mount rootfs, calculate actual used space with `du` |
| **3** | Query true minimum filesystem size via `resize2fs -P` |
| **4** | Add metadata margin (5% or 512MB min) + headroom |
| **5** | `e2fsck` → `resize2fs` → shrink LV/image/ZFS volume |
| **6** | Auto-retry with +2GB increments if resize2fs fails (up to 5 attempts) |
| **7** | Update container config with new size |

**Supported storage backends:**

| Backend | Method |
|---|---|
| **LVM / LVM-thin** | `resize2fs` + `lvresize` |
| **Directory (raw)** | `resize2fs` via losetup + `truncate` |
| **Directory (qcow2)** | Convert to raw → shrink → convert back |
| **ZFS** | `resize2fs` + `zfs set volsize` |

> **Tip:** You can also use `--shrink` directly in `lxc-to-vm.sh` instead of running `shrink-lxc.sh` separately. See [Integrated Shrink + Convert](#--shrink-integrated-shrink--convert).

---

## Feature Deep Dives

### `--shrink` (Integrated Shrink + Convert)

When you pass `--shrink` to `lxc-to-vm.sh`, the script:

1. **Skips the disk size prompt** — no need to specify `-d`
2. **Measures** actual used space inside the container
3. **Calculates** the optimal target: data + 5% metadata margin (min 512MB) + 1GB headroom
4. **Queries** `resize2fs -P` for the true minimum filesystem size
5. **Auto-adjusts** if the calculated target is below the filesystem minimum
6. **Auto-retries** up to 5 times (+2GB each) if resize2fs fails
7. **Shrinks** the LV/image/ZFS volume and updates the container config
8. **Auto-sets** the VM disk size to match the shrunk container
9. **Proceeds** with the normal conversion

```bash
# One command: shrink 200GB → ~31GB, convert to VM, boot it
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start
```

You can still override with `-d 50` if you want the VM disk larger than the shrunk size.

### `--dry-run` (Preview Mode)

Shows a full summary of what would happen without making any changes:

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --dry-run
```

Output includes: source/target config, LXC memory/cores, disk space check (pass/fail), step-by-step plan, and all active flags.

### `--bios ovmf` (UEFI Boot)

Switches from the default MBR/SeaBIOS to GPT/OVMF:

- Creates a **GPT** partition table with a **512MB FAT32 EFI System Partition**
- Installs the distro-appropriate EFI GRUB package (`grub-efi-amd64`, `grub-efi`, `grub2-efi-x64`, or `grub + efibootmgr`)
- Mounts `/boot/efi` and runs `grub-install --removable`
- Adds an **efidisk0** to the VM for OVMF firmware storage
- Handles EFI partition mount/unmount in the cleanup trap

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 -B ovmf
```

### `--keep-network` (Network Preservation)

Controls how networking is configured inside the VM:

| Mode | Behavior |
|---|---|
| **Default** (no flag) | Replaces all network config with DHCP on `ens18`. Comments out `eth0` entries. Writes a fresh Netplan config if applicable. |
| **`--keep-network`** | Preserves the original network config. Translates `eth0` → `ens18` in-place across `/etc/network/interfaces` and all Netplan YAML files. Adds an `ens18` adapter without removing existing configs. |

```bash
# Keep static IPs, bonding, VLANs, etc. — just swap eth0 → ens18
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --keep-network
```

### `--start` (Auto-Start & Health Checks)

After conversion, automatically boots the VM and runs live health checks:

1. Starts the VM via `qm start`
2. Waits up to 120 seconds for QEMU guest agent to respond
3. Queries guest agent for IP address on `ens18`
4. Performs a ping reachability test
5. Reports guest OS info

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --start
```

### Disk Space Management

The converter needs **filesystem space** for a temporary raw disk image before importing it to your target storage. This is important to understand:

- **LVM / LVM-thin / ZFS** storage pools **cannot** be used as working directories — they don't provide traditional filesystem space.
- The temp image is written to a filesystem directory, then imported via `qm importdisk`.
- Default working directory: `/var/lib/vz/dump/` (usually on your root filesystem).

**What happens when the default doesn't have enough space:**

1. The script checks available space and shows a clear message explaining why.
2. If **one** mount point has enough space, it's **auto-selected** (no prompt).
3. If **multiple** mount points qualify, a numbered menu lets you pick.
4. Use `--temp-dir` to pre-specify an alternative: `-t /mnt/bigdisk`
5. Use `--shrink` to reduce the required temp space by shrinking the container first.

### Post-Conversion Validation

After creating the VM, the script automatically runs a **6-point validation check**:

| Check | What it verifies |
|---|---|
| **VM config** | VM exists and config is readable |
| **Disk attachment** | `scsi0` is attached to the correct storage |
| **Boot order** | `scsi0` is in the boot order |
| **Network** | `net0` is configured with the correct bridge |
| **EFI disk** | `efidisk0` is present (only for UEFI/OVMF) |
| **Guest agent** | QEMU guest agent is enabled in VM config |

Results are shown as pass/fail with a summary count. This runs automatically — no flag needed.

### Batch & Range Conversion

Convert multiple containers at once using batch files or range specifications:

**Batch file format** (`conversions.txt`):
```
# Comment lines start with #
100 200
101 201
105 205
```

Run batch conversion:
```bash
sudo ./lxc-to-vm.sh --batch conversions.txt
```

**Range mode** converts a sequence of CTs to VMs:
```bash
# Convert CT 100-110 to VMs 200-210 (same count required)
sudo ./lxc-to-vm.sh --range 100-110:200-210 -s local-lvm --shrink
```

The script processes each conversion sequentially with a summary at the end showing successful/failed conversions.

### Snapshot & Rollback

Create a snapshot before conversion for instant rollback if something goes wrong:

```bash
# Create snapshot, convert, auto-rollback on failure
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --snapshot --rollback-on-failure
```

How it works:
1. Creates snapshot `pre-conversion-<timestamp>` before any changes
2. If conversion fails and `--rollback-on-failure` is set, automatically restores the container
3. On success, the snapshot is removed (unless the conversion failed)

**Manual rollback** (if needed):
```bash
pct rollback 100 pre-conversion-20250211-143022
```

### Configuration Profiles

Save common conversion settings for reuse:

```bash
# Save current settings as a profile
sudo ./lxc-to-vm.sh -s local-lvm -B ovmf --keep-network --save-profile webserver

# List saved profiles
sudo ./lxc-to-vm.sh --list-profiles

# Use a profile (combine with other flags)
sudo ./lxc-to-vm.sh -c 100 -v 200 --profile webserver

# Override profile settings with CLI flags
sudo ./lxc-to-vm.sh -c 100 -v 200 --profile webserver -b vmbr1
```

Profiles are stored in `/var/lib/lxc-to-vm/profiles/`.

### Resume Capability

If a long conversion is interrupted (SSH disconnect, power loss), resume from where it left off:

```bash
# Start conversion
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 200

# If interrupted, resume with:
sudo ./lxc-to-vm.sh -c 100 -v 200 --resume
```

Resume state includes:
- Partial rsync data (in `${TEMP_DIR}/.rsync-partial`)
- Conversion stage tracking
- Timestamp of last attempt

Resume only works for the rsync stage. If conversion fails during bootloader injection or VM creation, the resume state is cleared and you must restart.

### Auto-Destroy Source Container

After successful VM conversion, automatically remove the original LXC:

```bash
# Convert, start VM, verify health, then destroy original
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start --destroy-source
```

**Warning:** Only use `--destroy-source` after testing your VM works. Combine with `--snapshot` for extra safety:

```bash
# Full safe migration: snapshot, convert, verify, destroy
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --snapshot --rollback-on-failure --shrink --start --destroy-source
```

---

## v6.0.0 Feature Deep Dives

### Wizard Mode (--wizard)

Launch an interactive TUI wizard with progress bars and guided setup:

```bash
sudo ./lxc-to-vm.sh --wizard
```

The wizard guides you through:
1. Selecting source container and target VM ID
2. Choosing storage target
3. Shrink and disk size options
4. UEFI/BIOS selection
5. Network configuration options
6. Snapshot and rollback preferences
7. Auto-start and cleanup options
8. Progress bars during conversion with real-time status

### Parallel Batch Processing (--parallel)

Run multiple conversions concurrently for mass migrations:

```bash
# Process 4 containers simultaneously
sudo ./lxc-to-vm.sh --batch conversions.txt --parallel 4
```

Benefits:
- **Faster mass migrations** — multiple containers convert simultaneously
- **Resource management** — controls concurrent disk I/O and memory usage
- **Progress tracking** — shows which conversions are running/completed

Best practices:
- Set parallel jobs based on your I/O capacity (start with 2-4)
- Monitor disk and network utilization
- Each conversion still gets its own validation and logging

### Pre-Flight Validation (--validate-only)

Check if a container is ready for conversion without making changes:

```bash
# Validate single container
sudo ./lxc-to-vm.sh -c 100 --validate-only

# Validate with specific container
sudo ./lxc-to-vm.sh --validate-only -c 105
```

Checks performed:
- Container exists and is accessible
- Container state (stopped vs running)
- Distro detection and compatibility
- Root filesystem type
- Network configuration
- Storage availability
- Required dependencies

Output includes a readiness score and specific recommendations.

### Cloud/Remote Storage Export (--export-to)

Automatically export the VM disk after successful conversion:

```bash
# Export to AWS S3
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --export-to s3://my-backup-bucket/vms/

# Export to NFS share
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --export-to nfs://nas-server/backup/

# Export via SSH
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --export-to ssh://backup-server:/storage/vms/
```

Supported destinations:
- **S3**: Requires `aws` CLI configured
- **NFS**: Mounts and copies (ensure NFS is mounted first)
- **SSH/SCP**: Requires SSH key authentication

Combine with batch mode for automated backup workflows.

### VM Template Creation (--as-template)

Convert a container directly to a Proxmox VM template:

```bash
# Create template from container
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --as-template

# Template with sysprep for cloning
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --as-template --sysprep
```

What is a VM template?
- Read-only VM base image for rapid cloning
- Ideal for creating golden images from configured containers
- Clones start faster than new installations

**Sysprep option** (`--sysprep`):
- Removes SSH host keys
- Clears machine-id
- Removes persistent network rules
- Truncates logs
- Cleans temp files

This creates a clean image safe for cloning without identity conflicts.

### Complete Migration Example

Full workflow combining multiple v6.0.0 features:

```bash
# 1. Validate the container first
sudo ./lxc-to-vm.sh -c 100 --validate-only

# 2. Run wizard for guided setup
sudo ./lxc-to-vm.sh --wizard

# 3. Full automated migration with all safety features
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --shrink \
  --snapshot \
  --rollback-on-failure \
  --start \
  --destroy-source \
  --export-to s3://backup/vms/

# 4. Batch migrate 10 containers with 3 parallel jobs
sudo ./lxc-to-vm.sh --batch production-vms.txt --parallel 3

# 5. Create golden image template
sudo ./lxc-to-vm.sh -c 100 -v 900 -s local-lvm \
  --as-template --sysprep --snapshot
```

---

## Post-Conversion Steps

After the script completes (especially if you didn't use `--start`):

1. **Review the VM configuration:**
   ```bash
   qm config <VMID>
   ```

2. **Start the VM:**
   ```bash
   qm start <VMID>
   ```

3. **Access the console** (serial):
   ```bash
   qm terminal <VMID> -iface serial0
   ```

4. **Verify networking** — the VM is configured for DHCP on `ens18` (or preserved config if `--keep-network` was used). Check with `ip a` inside the VM.

5. **Install QEMU guest agent** (if not already present):
   ```bash
   # Debian/Ubuntu
   apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent

   # Alpine
   apk add qemu-guest-agent && rc-update add qemu-guest-agent

   # RHEL/CentOS
   yum install qemu-guest-agent && systemctl enable --now qemu-guest-agent

   # Arch
   pacman -S qemu-guest-agent && systemctl enable --now qemu-guest-agent
   ```

6. **Remove the old LXC** (only after verifying the VM works):
   ```bash
   pct destroy <CTID>
   ```

---

## Troubleshooting

### VM doesn't boot

- **Check boot order:** Proxmox GUI → VM → Options → Boot Order → ensure `scsi0` is first.
- **Check disk attachment:** `qm config <VMID> | grep scsi0` — should show the storage volume.
- **UEFI issues:** If using `--bios ovmf`, verify `efidisk0` exists: `qm config <VMID> | grep efidisk`.
- **Check GRUB:** Boot from a rescue ISO and run `grub-install` manually if needed.
- **Check the log:** `cat /var/log/lxc-to-vm.log` for detailed chroot output.

### VM boots but no network

- Verify the VM NIC is on the correct bridge: `qm config <VMID> | grep net0`
- Inside the VM, check `ip a` — the interface should be `ens18`.
- For Netplan-based systems: `ls /etc/netplan/` and run `netplan apply`.
- For traditional interfaces: check `/etc/network/interfaces` for `ens18`.
- If you used `--keep-network`, verify that `eth0` was translated to `ens18`.

### "Container does not exist" error

- Verify the container ID: `pct list`

### "Storage not found" error

- List available storage: `pvesm status`
- Ensure you're using the storage **name**, not the path.

### Script fails mid-way

- The cleanup trap automatically removes temp files and loop devices.
- Check the log for details: `cat /var/log/lxc-to-vm.log`
- If loop devices are stuck: `losetup -D` (detaches all).

### Disk space issues

- The script checks available space **before starting** and will warn you if there isn't enough room.
- **LVM/ZFS storage ≠ filesystem space.** Even if `local-lvm` has 500GB free, the temp image needs *filesystem* space (e.g. on `/`, `/mnt`, or another mount point).
- If only one mount point has enough space, it's **auto-selected** (no prompt needed).
- Use `--shrink` to reduce the required temp space by shrinking the container first.
- Use `--temp-dir` to specify a path with enough room:
  ```bash
  sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 200 -t /mnt/scratch
  ```
- Required space: at least `DISK_SIZE + 1 GB` on the working directory's filesystem.

### Shrink fails (resize2fs error)

- The shrink script auto-retries with +2GB increments. If it fails after 5 attempts, check `cat /var/log/shrink-lxc.log`.
- You can manually increase headroom: `./shrink-lxc.sh -c 100 -g 5`
- Ensure the container is **stopped** before shrinking.
- If the filesystem is corrupted, run `e2fsck` manually on the LV path shown in the error.

---

## Limitations

- **Single-disk containers** — multi-mount-point LXC configs are not handled.
- **No ZFS-to-ZFS** — the disk is always created as a raw image and imported. Native ZFS dataset cloning is not used.
- **Proxmox host only** — must be run directly on the Proxmox VE node, not remotely.
- **x86_64 only** — ARM-based containers are not supported.
- **ext4 filesystems** — the shrink and conversion scripts assume ext4. Other filesystems (XFS, btrfs) are not supported.

---

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Commit your changes: `git commit -m 'Add my feature'`
4. Push to the branch: `git push origin feature/my-feature`
5. Open a Pull Request

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

## Changelog

### v6.0.0 (2025-02-11)
**"Enterprise Edition" — 5 new features to reach 10/10**

- **Wizard Mode** (`--wizard`) — Interactive TUI with progress bars and guided setup
- **Parallel Batch Processing** (`--parallel N`) — Run multiple conversions concurrently
- **Pre-Flight Validation** (`--validate-only`) — Check container readiness without converting
- **Cloud/Remote Export** (`--export-to`) — Export to S3, NFS, or SSH destinations
- **VM Template Creation** (`--as-template`, `--sysprep`) — Create golden images from containers

### v5.0.0 (2025-02-11)
**"Safety & Scale Edition" — 5 new features**

- **Batch Conversion** (`--batch`) — Convert multiple containers from file
- **Range Conversion** (`--range`) — Convert CT range to VM range
- **Snapshots** (`--snapshot`) — Pre-conversion snapshots for rollback safety
- **Auto-Rollback** (`--rollback-on-failure`) — Automatic restore on failure
- **Configuration Profiles** (`--save-profile`, `--profile`) — Save and reuse settings
- **Resume Capability** (`--resume`) — Resume interrupted conversions
- **Auto-Destroy Source** (`--destroy-source`) — Remove original LXC after success

### v4.0.0
**"Foundation Edition" — Core conversion features**

- Multi-distro support (Debian, Ubuntu, Alpine, RHEL, Arch)
- BIOS & UEFI boot support
- Integrated disk shrink
- Dry-run mode
- Network preservation
- Auto-start & health checks
- Post-conversion validation
- Interactive & non-interactive modes
- Smart disk space management
