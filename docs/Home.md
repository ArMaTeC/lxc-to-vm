# Proxmox LXC ↔️ VM Converter Wiki

Welcome to the comprehensive documentation for the Proxmox LXC ↔️ VM Converter suite!

## 📚 Quick Navigation

| Guide | Description |
| ----- | ----------- |
| **[Installation](Installation)** | Get started with installation and setup |
| **[lxc-to-vm.sh](lxc-to-vm)** | Convert LXC containers to KVM VMs |
| **[vm-to-lxc.sh](vm-to-lxc)** | Convert KVM VMs to LXC containers |
| **[shrink-lxc.sh](shrink-lxc)** | Shrink LXC containers before conversion |
| **[Hooks System](Hooks)** | Extend with custom hooks |
| **[Troubleshooting](Troubleshooting)** | Common issues and solutions |
| **[API & Automation](API-Automation)** | Automate with API and scripting |
| **[Examples](Examples)** | Real-world examples and best practices |

## 🎯 What This Project Does

This project provides bidirectional conversion between Proxmox VE LXC containers and KVM virtual machines, enabling seamless workload migration with minimal downtime.

### Key Capabilities

- **Bidirectional Conversion**: LXC → VM and VM → LXC
- **Intelligent Disk Shrinking**: Optimize disk space before conversion
- **Snapshot Safety**: Automatic snapshots with rollback capability
- **Batch Processing**: Convert multiple workloads at once
- **Hook System**: Extensible automation via custom scripts
- **Network Preservation**: Maintain or reconfigure network settings
- **API Integration**: Proxmox VE API support for cluster operations

## 🚀 Quick Start

```bash
# Download the scripts
curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh
curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/vm-to-lxc.sh
curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-lxc.sh
chmod +x lxc-to-vm.sh vm-to-lxc.sh shrink-lxc.sh

# LXC to VM
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm

# VM to LXC
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm
```

## 📖 Documentation Structure

### Getting Started

- **Installation** - System requirements and setup
- **Quick Start** - Your first conversion
- **Examples** - Common use cases

### Script Documentation

- **lxc-to-vm.sh** - Complete LXC to VM guide
- **vm-to-lxc.sh** - Complete VM to LXC guide
- **shrink-lxc.sh** - Container optimization guide

### Advanced Topics

- **Hooks System** - Custom automation hooks
- **API & Automation** - Programmatic control
- **Batch Processing** - Mass conversion strategies

### Support

- **Troubleshooting** - Fix common issues
- **FAQ** - Frequently asked questions
- **Contributing** - Help improve the project

## 🔧 System Requirements

- Proxmox VE 7.x or 8.x
- Root access on Proxmox host
- Bash 4.0+
- Standard utilities: `rsync`, `qemu-img`, `parted`, etc.

See [Installation](Installation) for complete requirements.

## 🆘 Getting Help

- Check the [Troubleshooting](Troubleshooting) guide
- Browse [Examples](Examples) for similar use cases
- Review script exit codes in each script's documentation
- Check the [FAQ](FAQ) section

## 📜 License

MIT License - See [LICENSE](../LICENSE) for details.
