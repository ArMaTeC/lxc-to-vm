# Installation Guide

Complete installation and setup guide for the Proxmox LXC ↔️ VM Converter suite.

---

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Quick Installation](#quick-installation)
3. [Manual Installation](#manual-installation)
4. [System-Wide Installation](#system-wide-installation)
5. [Post-Installation](#post-installation)
6. [Verification](#verification)
7. [Uninstallation](#uninstallation)

---

## System Requirements

### Required

| Component | Requirement |
| --------- | ----------- |
| **OS** | Proxmox VE 7.x or 8.x |
| **Access** | Root access (or sudo privileges) |
| **Shell** | Bash 4.0+ |
| **Network** | Internet connection for dependency installation |

### Hardware

| Resource | Minimum | Recommended |
| -------- | ------- | ----------- |
| **RAM** | 2 GB | 4 GB+ |
| **Disk** | 10 GB free | 50 GB+ free |
| **CPU** | 2 cores | 4+ cores |

### Dependencies (Auto-Installed)

The scripts automatically install required packages:

| Package | Purpose |
| ------- | ------- |
| `rsync` | File synchronization |
| `qemu-utils` | Disk image handling (qemu-img, qemu-nbd) |
| `parted` | Partition management |
| `kpartx` | Partition mapping |
| `libguestfs-tools` | VM disk inspection |
| `util-linux` | Block device utilities |
| `ncurses-bin` | Dialog/TUI support |
| `curl` | API calls |
| `jq` | JSON processing |
| `pve-manager` | Proxmox CLI tools |

### Supported Distributions

**Source Containers/VMs:**

| Distribution | LXC → VM | VM → LXC | Notes |
| ------------ | -------- | -------- | ----- |
| Debian 10-12 | ✅ | ✅ | Full support |
| Ubuntu 20.04-24.04 | ✅ | ✅ | Full support |
| Alpine Linux 3.15+ | ✅ | ✅ | musl libc compatible |
| RHEL/CentOS/Rocky 7-9 | ✅ | ✅ | Includes EFI support |
| Arch Linux | ✅ | ✅ | Latest kernel |
| Fedora 38+ | ✅ | ✅ | Modern systemd |
| openSUSE Leap | ✅ | ✅ | btrfs supported |
| Kali Linux | ✅ | ✅ | Security tools |

---

## Quick Installation

### One-Liner Download

```bash
# Download all scripts into ~/lxc-to-vm
mkdir -p ~/lxc-to-vm && cd ~/lxc-to-vm \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh -o lxc-to-vm.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/vm-to-lxc.sh -o vm-to-lxc.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-lxc.sh -o shrink-lxc.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/expand-lxc.sh -o expand-lxc.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-vm.sh -o shrink-vm.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/expand-vm.sh -o expand-vm.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/clone-replace-disk.sh -o clone-replace-disk.sh \
  && chmod +x *.sh
```

### Git Clone

```bash
# Clone the repository
git clone https://github.com/ArMaTeC/lxc-to-vm.git
cd lxc-to-vm
chmod +x *.sh
```

---

## Manual Installation

### Step 1: Download Scripts

```bash
# Create installation directory
mkdir -p ~/lxc-to-vm
cd ~/lxc-to-vm

# Download each script
curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh
curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/vm-to-lxc.sh
curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-lxc.sh
curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/expand-lxc.sh
curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-vm.sh
curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/expand-vm.sh
curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/clone-replace-disk.sh

# Make executable
chmod +x *.sh
```

### Step 2: Install Dependencies

Dependencies are automatically installed on first run, or you can pre-install:

```bash
# Debian/Ubuntu/Proxmox
apt-get update
apt-get install -y rsync qemu-utils parted kpartx libguestfs-tools curl jq

# Enable NBD module (for VM disk access)
modprobe nbd max_part=8
```

### Step 3: Verify Installation

```bash
# From ~/lxc-to-vm
cd ~/lxc-to-vm
./lxc-to-vm.sh --version
./vm-to-lxc.sh --version
./shrink-lxc.sh --version
./expand-lxc.sh --version
./shrink-vm.sh --version
./expand-vm.sh --version
./clone-replace-disk.sh --version
```

---

## System-Wide Installation

For production environments, install system-wide:

```bash
# Copy scripts to system path
cp lxc-to-vm.sh /usr/local/bin/lxc-to-vm
cp vm-to-lxc.sh /usr/local/bin/vm-to-lxc
cp shrink-lxc.sh /usr/local/bin/shrink-lxc
cp expand-lxc.sh /usr/local/bin/expand-lxc
cp shrink-vm.sh /usr/local/bin/shrink-vm
cp expand-vm.sh /usr/local/bin/expand-vm
cp clone-replace-disk.sh /usr/local/bin/clone-replace-disk
chmod +x /usr/local/bin/lxc-to-vm /usr/local/bin/vm-to-lxc /usr/local/bin/shrink-lxc \
  /usr/local/bin/expand-lxc /usr/local/bin/shrink-vm /usr/local/bin/expand-vm \
  /usr/local/bin/clone-replace-disk

# Create hook directories
mkdir -p /var/lib/lxc-to-vm/hooks /var/lib/lxc-to-vm/profiles /var/lib/lxc-to-vm/resume
mkdir -p /var/lib/vm-to-lxc/hooks /var/lib/vm-to-lxc/profiles /var/lib/vm-to-lxc/resume
mkdir -p /var/log

# Create log files
touch /var/log/lxc-to-vm.log /var/log/vm-to-lxc.log
chmod 644 /var/log/lxc-to-vm.log /var/log/vm-to-lxc.log

# Optional: Install example hooks
cp -r examples/hooks/* /var/lib/lxc-to-vm/hooks/ 2>/dev/null || true
cp -r examples-vm-to-lxc/hooks/* /var/lib/vm-to-lxc/hooks/ 2>/dev/null || true
```

### PATH Configuration

Ensure `/usr/local/bin` is in your PATH:

```bash
echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

---

## Post-Installation

### 1. Kernel Module Setup

For VM disk access, ensure NBD module is loaded:

```bash
# Load module immediately
modprobe nbd max_part=8

# Make persistent
echo "nbd" >> /etc/modules
echo "options nbd max_part=8" > /etc/modprobe.d/nbd.conf
```

### 2. Storage Validation

Verify your Proxmox storage is accessible:

```bash
# List available storage
pvesm status

# Check specific storage
pvesm path local-lvm
```

### 3. Test Conversion (Dry-Run)

Test without making changes:

```bash
# From ~/lxc-to-vm (or use system-wide names after system-wide install)
cd ~/lxc-to-vm

# LXC to VM dry-run
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --dry-run

# VM to LXC dry-run
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm --dry-run
```

---

## Verification

### Check Script Health

```bash
# Verify all scripts are present (system-wide install)
which lxc-to-vm vm-to-lxc shrink-lxc expand-lxc shrink-vm expand-vm clone-replace-disk

# Check versions
lxc-to-vm --version         # Should show 6.0.6
vm-to-lxc --version         # Should show 6.0.6
shrink-lxc --version        # Should show 6.0.6
expand-lxc --version        # Should show 6.0.0
shrink-vm --version         # Should show 6.0.0
expand-vm --version         # Should show 6.0.0
clone-replace-disk --version # Should show 1.0.0

# Test help output
lxc-to-vm --help
vm-to-lxc --help
shrink-lxc --help
expand-lxc --help
shrink-vm --help
expand-vm --help
clone-replace-disk --help
```

### Verify Dependencies

```bash
# Check required commands
command -v rsync qemu-img parted kpartx curl jq

# Check Proxmox tools
which qm pct pvesm pvesh

# Verify NBD module
lsmod | grep nbd
```

---

## Uninstallation

### Remove System-Wide Installation

```bash
# Remove binaries
rm -f /usr/local/bin/lxc-to-vm /usr/local/bin/vm-to-lxc /usr/local/bin/shrink-lxc \
  /usr/local/bin/expand-lxc /usr/local/bin/shrink-vm /usr/local/bin/expand-vm \
  /usr/local/bin/clone-replace-disk

# Remove hook directories (back up first if needed)
rm -rf /var/lib/lxc-to-vm /var/lib/vm-to-lxc

# Remove log files (optional)
rm -f /var/log/lxc-to-vm.log /var/log/vm-to-lxc.log

# Clean up cron jobs (if any)
crontab -l | grep -v "lxc-to-vm\|vm-to-lxc" | crontab -
```

### Remove Local Installation

```bash
# Remove the lxc-to-vm folder
rm -rf ~/lxc-to-vm
```

---

## Next Steps

- **[lxc-to-vm.sh Usage](lxc-to-vm)** - Learn LXC to VM conversion
- **[vm-to-lxc.sh Usage](vm-to-lxc)** - Learn VM to LXC conversion
- **[shrink-lxc.sh Usage](shrink-lxc)** - Optimize LXC containers
- **[expand-lxc.sh Usage](expand-lxc)** - Expand LXC container disks
- **[shrink-vm.sh Usage](shrink-vm)** - Shrink VM disks
- **[expand-vm.sh Usage](expand-vm)** - Expand VM disks
- **[clone-replace-disk.sh Usage](clone-replace-disk)** - Clone and replace disks
- **[Examples](Examples)** - See real-world use cases
