# Proxmox LXC ↔️ VM Converter Wiki

Welcome to the comprehensive documentation for the Proxmox LXC ↔️ VM Converter suite!

## 📚 Quick Navigation

| Guide | Description |
| ----- | ----------- |
| **[Installation](Installation)** | Get started with installation and setup |
| **[lxc-to-vm.sh](lxc-to-vm)** | Convert LXC containers to KVM VMs |
| **[vm-to-lxc.sh](vm-to-lxc)** | Convert KVM VMs to LXC containers |
| **[shrink-lxc.sh](shrink-lxc)** | Shrink LXC containers before conversion |
| **[expand-lxc.sh](expand-lxc)** | Expand LXC container disk space |
| **[shrink-vm.sh](shrink-vm)** | Shrink VM disk to actual usage |
| **[expand-vm.sh](expand-vm)** | Expand VM disk space |
| **[clone-replace-disk.sh](clone-replace-disk)** | Clone and replace VM/LXC disks |
| **[Hooks System](Hooks)** | Extend with custom hooks |
| **[Troubleshooting](Troubleshooting)** | Common issues and solutions |
| **[API & Automation](API-Automation)** | Automate with API and scripting |
| **[Examples](Examples)** | Real-world examples and best practices |

## 🎯 What This Project Does

This project provides bidirectional conversion between Proxmox VE LXC containers and KVM virtual machines, plus a full suite of disk management tools for expanding, shrinking, and cloning disks.

### Key Capabilities

- **Bidirectional Conversion**: LXC → VM and VM → LXC
- **Intelligent Disk Shrinking**: Shrink LXC and VM disks to actual usage
- **Flexible Disk Expansion**: Expand LXC and VM disks with multiple modes
- **Disk Clone & Replace**: Clone disks across storage backends
- **Snapshot Safety**: Automatic snapshots with rollback capability
- **Batch Processing**: Convert multiple workloads at once
- **Hook System**: Extensible automation via custom scripts
- **Network Preservation**: Maintain or reconfigure network settings
- **API Integration**: Proxmox VE API support for cluster operations

## 🚀 Quick Start

```bash
# Download all scripts into a lxc-to-vm folder
mkdir -p ~/lxc-to-vm && cd ~/lxc-to-vm \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh -o lxc-to-vm.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/vm-to-lxc.sh -o vm-to-lxc.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-lxc.sh -o shrink-lxc.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/expand-lxc.sh -o expand-lxc.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-vm.sh -o shrink-vm.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/expand-vm.sh -o expand-vm.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/clone-replace-disk.sh -o clone-replace-disk.sh \
  && chmod +x *.sh

# Run from the folder (cd ~/lxc-to-vm first if needed)

# LXC to VM
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm

# VM to LXC
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm

# Expand an LXC container disk
sudo ./expand-lxc.sh -c 100 -s 50

# Expand a VM disk
sudo ./expand-vm.sh -v 100 -a 20

# Shrink an LXC container disk
sudo ./shrink-lxc.sh -c 100

# Shrink a VM disk
sudo ./shrink-vm.sh -v 100

# Clone and replace a disk
sudo ./clone-replace-disk.sh -t lxc -i 100 --size 200
```

## 📖 Documentation Structure

### Getting Started

- **Installation** - System requirements and setup
- **Quick Start** - Your first conversion
- **Examples** - Common use cases

### Script Documentation

- **lxc-to-vm.sh** - Complete LXC to VM guide
- **vm-to-lxc.sh** - Complete VM to LXC guide
- **shrink-lxc.sh** - Container disk optimization guide
- **expand-lxc.sh** - Container disk expansion guide
- **shrink-vm.sh** - VM disk shrink guide
- **expand-vm.sh** - VM disk expansion guide
- **clone-replace-disk.sh** - Disk clone and replace guide

### Advanced Topics

- **Hooks System** - Custom automation hooks
- **API & Automation** - Programmatic control
- **Batch Processing** - Mass conversion strategies

### Support

- **Troubleshooting** - Fix common issues
- **Contributing** - Help improve the project

## 🔧 System Requirements

- Proxmox VE 7.x or 8.x
- Root access on Proxmox host
- Bash 4.0+
- Standard utilities: `rsync`, `qemu-img`, `parted`, `e2fsck`, `resize2fs`, etc.

See [Installation](Installation) for complete requirements.

## 🆘 Getting Help

- Check the [Troubleshooting](Troubleshooting) guide
- Browse [Examples](Examples) for similar use cases
- Review script exit codes in each script's documentation
- Check logs: `/var/log/lxc-to-vm.log`, `/var/log/vm-to-lxc.log`, `/var/log/expand-lxc.log`, etc.

## 📜 License

MIT License - See [LICENSE](../LICENSE) for details.
