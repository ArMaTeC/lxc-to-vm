# 🚀 Proxmox LXC ↔️ VM Converter

<!-- markdownlint-disable MD013 -->

[![Release](https://img.shields.io/github/v/release/ArMaTeC/lxc-to-vm?style=for-the-badge&color=blue)](https://github.com/ArMaTeC/lxc-to-vm/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen.svg?style=for-the-badge)](.github/workflows/shellcheck.yml)

**Convert Proxmox LXC containers into fully bootable QEMU/KVM virtual machines — and back again!** ⚡

📚 **[Full Documentation →](https://github.com/ArMaTeC/lxc-to-vm/wiki)**

---

## ✨ Features

- **🔄 Bidirectional Conversion** - LXC ↔ VM and VM ↔ LXC
- **🐧 Multi-Distro Support** - Debian, Ubuntu, Alpine, RHEL/CentOS/Rocky, Arch Linux
- **📉 Smart Disk Shrinking** - Optimize disk size before conversion
- **� Flexible Disk Expansion** - Grow containers with multiple expansion modes
- **�️ Snapshot Safety** - Automatic rollback on failure
- **📊 Batch Processing** - Convert multiple workloads at once
- **🔌 Hook System** - Custom automation at every stage
- **🧙 Interactive Wizard** - TUI mode for guided conversion
- **☁️ Cloud Export** - Export to S3, NFS, or remote storage

---

## 🚀 Quick Start

### Installation

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

Or clone the repository:

```bash
git clone https://github.com/ArMaTeC/lxc-to-vm.git
cd lxc-to-vm
chmod +x *.sh
```

### LXC to VM

```bash
# Interactive mode
sudo ./lxc-to-vm.sh

# Non-interactive
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --start

# Shrink + Convert
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --start
```

### Expand LXC (Standalone)

```bash
# Expand to specific size
sudo ./expand-lxc.sh -c 100 -s 100

# Add space to current size
sudo ./expand-lxc.sh -c 100 -a 50

# Use maximum available space
sudo ./expand-lxc.sh -c 100 --max

# Hot-expand without restart (LVM/ZFS supported)
sudo ./expand-lxc.sh -c 100 -s 200 --no-restart
```

### VM to LXC

```bash
# Interactive mode
sudo ./vm-to-lxc.sh

# Non-interactive
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm --start

# With snapshot safety
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm --snapshot --start
```

### Shrink LXC (Standalone)

```bash
# Optimize container before manual operations
sudo ./shrink-lxc.sh -c 100

# Show help options
sudo ./shrink-lxc.sh -c 100 --help
```

### Shrink VM (Standalone)

```bash
# Shrink VM to usage + headroom
sudo ./shrink-vm.sh -v 100

# Shrink with 5GB extra headroom
sudo ./shrink-vm.sh -v 100 -g 5

# Use libguestfs for safer shrink (slower)
sudo ./shrink-vm.sh -v 100 -u

# Dry-run preview
sudo ./shrink-vm.sh -v 100 --dry-run
```

### Expand VM (Standalone)

```bash
# Expand VM to specific size
sudo ./expand-vm.sh -v 100 -s 100

# Add space to current size
sudo ./expand-vm.sh -v 100 -a 50

# Use maximum available space
sudo ./expand-vm.sh -v 100 --max

# Hot-expand while VM is running (LVM/ZFS/QCOW2)
sudo ./expand-vm.sh -v 100 -s 200 --hot-expand
```

### Clone & Replace Disk (Fix Expansion Issues)

```bash
# Fix: Proxmox shows expanded size but OS doesn't see it
sudo ./clone-replace-disk.sh -t lxc -i 133 --size 200

# Clone VM disk with expansion
sudo ./clone-replace-disk.sh -t vm -i 100 -d scsi0 --size 300

# Clone to different storage backend
sudo ./clone-replace-disk.sh -t lxc -i 100 -s zfspool --size 200

# Clone, replace, and remove old disk
sudo ./clone-replace-disk.sh -t vm -i 200 --size 250 --remove-old

# Preview changes
sudo ./clone-replace-disk.sh -t lxc -i 100 --size 200 --dry-run
```

---

## 📚 Documentation

| Guide | Description |
| ----- | ----------- |
| **[Wiki Home](https://github.com/ArMaTeC/lxc-to-vm/wiki)** | Overview and navigation |
| **[Installation](https://github.com/ArMaTeC/lxc-to-vm/wiki/Installation)** | System requirements and setup |
| **[lxc-to-vm.sh](https://github.com/ArMaTeC/lxc-to-vm/wiki/lxc-to-vm)** | Complete LXC to VM documentation |
| **[vm-to-lxc.sh](https://github.com/ArMaTeC/lxc-to-vm/wiki/vm-to-lxc)** | Complete VM to LXC documentation |
| **[shrink-lxc.sh](https://github.com/ArMaTeC/lxc-to-vm/wiki/shrink-lxc)** | Container optimization guide |
| **[expand-lxc.sh](https://github.com/ArMaTeC/lxc-to-vm/wiki/expand-lxc)** | Container expansion guide |
| **[shrink-vm.sh](https://github.com/ArMaTeC/lxc-to-vm/wiki/shrink-vm)** | VM disk shrink guide |
| **[expand-vm.sh](https://github.com/ArMaTeC/lxc-to-vm/wiki/expand-vm)** | VM disk expansion guide |
| **[clone-replace-disk.sh](https://github.com/ArMaTeC/lxc-to-vm/wiki/clone-replace-disk)** | Disk clone & replace tool |
| **[Hooks](https://github.com/ArMaTeC/lxc-to-vm/wiki/Hooks)** | Automation hook system |
| **[Troubleshooting](https://github.com/ArMaTeC/lxc-to-vm/wiki/Troubleshooting)** | Common issues and solutions |
| **[API & Automation](https://github.com/ArMaTeC/lxc-to-vm/wiki/API-Automation)** | CI/CD integration examples |
| **[Examples](https://github.com/ArMaTeC/lxc-to-vm/wiki/Examples)** | Real-world use cases |
| **[CHANGELOG](CHANGELOG.md)** | Version history and release notes |
| **[CONTRIBUTING](CONTRIBUTING.md)** | How to contribute |

---

## 🐧 Supported Distributions

| Distro | LXC → VM | VM → LXC |
| ------ | -------- | -------- |
| **Debian/Ubuntu** | ✅ | ✅ |
| **Alpine Linux** | ✅ | ✅ |
| **RHEL/CentOS/Rocky** | ✅ | ✅ |
| **Arch Linux** | ✅ | ✅ |

---

## 📦 Requirements

- Proxmox VE 7.x or 8.x
- Root access on Proxmox host
- Bash 4.0+

See [Installation Guide](https://github.com/ArMaTeC/lxc-to-vm/wiki/Installation) for complete requirements.

---

## 🗂️ Repository Structure

```text
lxc-to-vm/
├── lxc-to-vm.sh          # LXC to VM converter
├── vm-to-lxc.sh          # VM to LXC converter
├── shrink-lxc.sh         # Container optimizer
├── expand-lxc.sh         # Container expansion tool
├── shrink-vm.sh          # VM disk shrinker
├── expand-vm.sh          # VM disk expander
├── clone-replace-disk.sh # Disk clone & replace tool
├── examples/             # Hook examples for lxc-to-vm
├── docs/                 # Wiki source files
├── test-remote-pve.sh    # Automated remote PVE test helper
├── CHANGELOG.md          # Version history
├── CONTRIBUTING.md       # Contribution guidelines
└── README.md             # This file
```

---

## 🆘 Getting Help

- Check the **[Wiki Documentation](https://github.com/ArMaTeC/lxc-to-vm/wiki)**
- Review **[Troubleshooting Guide](https://github.com/ArMaTeC/lxc-to-vm/wiki/Troubleshooting)**
- View script logs (all in `/var/log/`):
  - `lxc-to-vm.log`, `vm-to-lxc.log`, `shrink-lxc.log`
  - `expand-lxc.log`, `shrink-vm.log`, `expand-vm.log`, `clone-replace-disk.log`
- [Open an Issue](https://github.com/ArMaTeC/lxc-to-vm/issues)

---

## 🤝 Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## 📄 License

MIT License - See [LICENSE](LICENSE) for details.

---

## ☕ Support

If you find this project helpful, consider buying me a coffee!

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-PayPal-blue?style=for-the-badge&logo=paypal)](https://www.paypal.com/paypalme/CityLifeRPG)

---

Made with ❤️ for the Proxmox community
