# Proxmox LXC to VM Converter

[![Release](https://github.com/ArMaTeC/lxc-to-vm/actions/workflows/release.yml/badge.svg)](https://github.com/ArMaTeC/lxc-to-vm/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A robust Bash script that converts **Proxmox LXC containers** into fully bootable **QEMU/KVM virtual machines** — directly on your Proxmox VE host. It handles disk creation, filesystem copy, kernel/GRUB installation, networking reconfiguration, and VM provisioning automatically.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Usage](#usage)
  - [Interactive Mode](#interactive-mode)
  - [Non-Interactive Mode](#non-interactive-mode)
  - [Options Reference](#options-reference)
- [How It Works](#how-it-works)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **One-command conversion** — turn any LXC into a bootable VM
- **Multi-distro support** — Debian, Ubuntu, Alpine, CentOS/RHEL/Rocky, Arch Linux (auto-detected)
- **BIOS & UEFI boot** — MBR/SeaBIOS (default) or GPT/OVMF with `--bios ovmf`
- **Dry-run mode** — preview every step without making changes (`--dry-run`)
- **Network preservation** — keep original network config with `--keep-network`, or replace with DHCP on `ens18`
- **Auto-start & health checks** — boot the VM and verify guest agent, IP, and reachability (`--start`)
- **Post-conversion validation** — automatic 6-point check (disk, boot order, network, agent, EFI)
- **Interactive & non-interactive modes** — use CLI flags for scripting or answer prompts manually
- **Auto-dependency installation** — missing tools (`parted`, `kpartx`, `rsync`, etc.) are installed automatically
- **Input validation** — catches invalid IDs, missing storage, and format errors before work begins
- **Storage validation** — verifies the target Proxmox storage exists before proceeding
- **Disk space pre-check** — verifies sufficient space; suggests alternative mount points if needed
- **Custom working directory** — use `--temp-dir` to place the temporary disk image on any mount point
- **LXC config inheritance** — memory, CPU cores are pulled from the source container config
- **Serial console support** — enables `ttyS0` serial console for Proxmox terminal access
- **Colored output** — clear, color-coded progress messages (auto-disabled when piped)
- **Full logging** — all operations logged to `/var/log/lxc-to-vm.log`
- **Safe cleanup** — trap-based cleanup removes temp files and loop devices on exit or error
- **Multiple disk formats** — supports `qcow2` (default), `raw`, and `vmdk`

---

## Requirements

| Requirement | Details |
|---|---|
| **Proxmox VE** | Version 7.x or 8.x |
| **Source LXC** | Debian, Ubuntu, Alpine, CentOS/RHEL/Rocky, or Arch based container |
| **Root access** | Script must run as `root` on the Proxmox host |
| **Free disk space** | At least 2× the container's used space in `/var/lib/vz/dump/` |
| **Network** | Internet access (to install kernel/GRUB packages inside chroot) |

### Dependencies (auto-installed)

- `parted` — disk partitioning
- `kpartx` — partition mapping for loop devices
- `rsync` — filesystem copy
- `e2fsprogs` — ext4 formatting (`mkfs.ext4`)

---

## Quick Start

```bash
# Download the scripts
wget https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh
wget https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-lxc.sh

# Make them executable
chmod +x lxc-to-vm.sh shrink-lxc.sh

# (Optional) Shrink a large container before converting
sudo ./shrink-lxc.sh -c 100

# Convert LXC to VM (interactive mode)
sudo ./lxc-to-vm.sh
```

Or clone the repository:

```bash
git clone https://github.com/ArMaTeC/lxc-to-vm.git
cd lxc-to-vm
sudo ./lxc-to-vm.sh
```

### Shrink Before Convert

If your container has a large disk (e.g. 200GB) but only uses a fraction of it, shrink it first to save time and temp disk space:

```bash
# Shrink CT 100's disk to usage + 1GB headroom
sudo ./shrink-lxc.sh -c 100

# Preview without changes
sudo ./shrink-lxc.sh -c 100 --dry-run

# Custom headroom (2GB)
sudo ./shrink-lxc.sh -c 100 -g 2
```

The shrink script supports **LVM-thin**, **directory** (raw/qcow2), and **ZFS** storage backends.

---

## Usage

### Interactive Mode

Simply run the script without arguments. You will be prompted for each required value:

```bash
sudo ./lxc-to-vm.sh
```

```
==========================================
   PROXMOX LXC TO VM CONVERTER v4.0.0
==========================================
Enter Source Container ID (e.g., 100): 100
Enter New VM ID (e.g., 200): 200
Enter Target Storage Name (e.g., local-lvm): local-lvm
Enter Disk Size in GB (must be > used space, e.g., 32): 32
```

### Non-Interactive Mode

Pass all required values as command-line flags — ideal for automation and scripting:

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
    --start
```

### Options Reference

| Short | Long | Description | Default |
|---|---|---|---|
| `-c` | `--ctid` | Source LXC container ID | *(prompted)* |
| `-v` | `--vmid` | Target VM ID | *(prompted)* |
| `-s` | `--storage` | Proxmox storage name | *(prompted)* |
| `-d` | `--disk-size` | Disk size in GB | *(prompted)* |
| `-f` | `--format` | Disk image format (`qcow2`, `raw`, `vmdk`) | `qcow2` |
| `-b` | `--bridge` | Network bridge name | `vmbr0` |
| `-t` | `--temp-dir` | Working directory for the temp disk image | `/var/lib/vz/dump` |
| `-B` | `--bios` | Firmware type (`seabios` or `ovmf` for UEFI) | `seabios` |
| `-n` | `--dry-run` | Preview what would happen without making changes | — |
| `-k` | `--keep-network` | Preserve original network config (translate eth0→ens18) | — |
| `-S` | `--start` | Auto-start VM after conversion and run health checks | — |
| `-h` | `--help` | Show help message | — |
| `-V` | `--version` | Print version | — |

---

## How It Works

The conversion follows eight stages:

```
┌─────────────────────────────────────────────────┐
│  1. ARGUMENT PARSING & VALIDATION               │
│     Parse CLI flags or prompt interactively.     │
│     Validate IDs, storage, format, BIOS type.    │
├─────────────────────────────────────────────────┤
│  2. DRY-RUN CHECK (if --dry-run)                │
│     Show full plan + space check, then exit.     │
├─────────────────────────────────────────────────┤
│  3. DISK CREATION                               │
│     MBR/BIOS or GPT/UEFI+ESP partitioning.      │
│     Format ext4 (+ FAT32 ESP for UEFI).         │
├─────────────────────────────────────────────────┤
│  4. DATA COPY                                   │
│     Mount LXC rootfs via pct mount.              │
│     rsync entire filesystem (excluding virtual   │
│     filesystems: /dev, /proc, /sys, etc.).       │
├─────────────────────────────────────────────────┤
│  5. BOOTLOADER INJECTION (CHROOT)               │
│     Auto-detect distro (apt/apk/yum/pacman).    │
│     Write /etc/fstab, configure networking.      │
│     Install kernel + GRUB (BIOS or EFI).        │
├─────────────────────────────────────────────────┤
│  6. VM CREATION                                 │
│     Create VM (qm create), import disk.         │
│     Add EFI disk for UEFI if needed.             │
├─────────────────────────────────────────────────┤
│  7. POST-CONVERSION VALIDATION                  │
│     6-point check: disk, boot, network, agent.  │
├─────────────────────────────────────────────────┤
│  8. AUTO-START & HEALTH CHECK (if --start)      │
│     Boot VM, wait for guest agent, verify IP.    │
└─────────────────────────────────────────────────┘
```

---

## Examples

### Convert container 105 to VM 300 on local-lvm with 20GB disk

```bash
sudo ./lxc-to-vm.sh -c 105 -v 300 -s local-lvm -d 20
```

### Convert with raw disk format on a specific bridge

```bash
sudo ./lxc-to-vm.sh -c 105 -v 300 -s local-lvm -d 20 -f raw -b vmbr1
```

### Large container — use an alternative temp directory with more space

```bash
sudo ./lxc-to-vm.sh -c 127 -v 300 -s local-lvm -d 201 -f raw -t /mnt/bigdisk
```

### UEFI boot with auto-start and health checks

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 -B ovmf --start
```

### Dry-run — preview the conversion plan without doing anything

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --dry-run
```

### Keep existing network config (translate eth0 → ens18)

```bash
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --keep-network
```

### Convert an Alpine LXC

```bash
sudo ./lxc-to-vm.sh -c 110 -v 210 -s local-lvm -d 10
# Distro is auto-detected — Alpine packages (apk) are used automatically
```

### Check the version

```bash
./lxc-to-vm.sh --version
# v4.0.0
```

### View the log after conversion

```bash
cat /var/log/lxc-to-vm.log
```

---

## Post-Conversion Steps

After the script completes:

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

4. **Verify networking** — the VM is configured for DHCP on `ens18`. If you need a static IP, edit `/etc/network/interfaces` or the Netplan config inside the VM.

5. **Install QEMU guest agent** (if not already present):
   ```bash
   apt install qemu-guest-agent
   systemctl enable --now qemu-guest-agent
   ```

6. **Remove the old LXC** (only after verifying the VM works):
   ```bash
   pct destroy <CTID>
   ```

---

## Troubleshooting

### VM doesn't boot

- **Check boot order:** In the Proxmox GUI, go to VM → Hardware → confirm `scsi0` is listed. Then go to Options → Boot Order → ensure `scsi0` is first.
- **Check GRUB:** If GRUB wasn't installed correctly, boot from a rescue ISO and run `grub-install` manually.

### VM boots but no network

- Verify the VM NIC is on the correct bridge (`vmbr0` by default).
- Inside the VM, check `ip a` — the interface should be `ens18`.
- For Netplan-based systems, verify `/etc/netplan/01-netcfg.yaml` exists and run `netplan apply`.

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
- In interactive mode, it lists mount points with sufficient space and lets you pick one.
- In non-interactive mode, use `--temp-dir` to specify a path with enough room:
  ```bash
  sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 200 -t /mnt/scratch
  ```
- Required space: at least `DISK_SIZE + 1 GB` on the working directory's filesystem.

---

## Supported Distros

| Distro Family | Detected IDs | Package Manager | Notes |
|---|---|---|---|
| **Debian/Ubuntu** | `debian`, `ubuntu`, `linuxmint`, `pop`, `kali` | `apt` | Primary target, most tested |
| **Alpine** | `alpine` | `apk` | OpenRC init system configured automatically |
| **RHEL/CentOS** | `centos`, `rhel`, `rocky`, `alma`, `fedora` | `yum`/`dnf` | Kernel + GRUB2 |
| **Arch Linux** | `arch`, `manjaro`, `endeavouros` | `pacman` | Kernel + GRUB |

Distro is auto-detected from `/etc/os-release` inside the container.

---

## Limitations

- **Single-disk containers** — multi-mount-point LXC configs are not handled.
- **No ZFS-to-ZFS** — the disk is always created as a raw image and imported. Native ZFS dataset cloning is not used.
- **Proxmox host only** — must be run directly on the Proxmox VE node, not remotely.
- **x86_64 only** — ARM-based containers are not supported.

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
