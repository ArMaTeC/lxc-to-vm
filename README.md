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
- **🛡️ Snapshot Safety** - Automatic rollback on failure
- **📊 Batch Processing** - Convert multiple workloads at once
- **🔌 Hook System** - Custom automation at every stage
- **🧙 Interactive Wizard** - TUI mode for guided conversion
- **☁️ Cloud Export** - Export to S3, NFS, or remote storage

---

## 🚀 Quick Start

### Installation

```bash
# Download all scripts
curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh -o lxc-to-vm.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/vm-to-lxc.sh -o vm-to-lxc.sh \
  && curl -fsSL https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/shrink-lxc.sh -o shrink-lxc.sh \
  && chmod +x lxc-to-vm.sh vm-to-lxc.sh shrink-lxc.sh
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

---

## 📚 Documentation

| Guide | Description |
| ----- | ----------- |
| **[Wiki Home](https://github.com/ArMaTeC/lxc-to-vm/wiki)** | Overview and navigation |
| **[Installation](https://github.com/ArMaTeC/lxc-to-vm/wiki/Installation)** | System requirements and setup |
| **[lxc-to-vm.sh](https://github.com/ArMaTeC/lxc-to-vm/wiki/lxc-to-vm)** | Complete LXC to VM documentation |
| **[vm-to-lxc.sh](https://github.com/ArMaTeC/lxc-to-vm/wiki/vm-to-lxc)** | Complete VM to LXC documentation |
| **[shrink-lxc.sh](https://github.com/ArMaTeC/lxc-to-vm/wiki/shrink-lxc)** | Container optimization guide |
| **[Hooks](https://github.com/ArMaTeC/lxc-to-vm/wiki/Hooks)** | Automation hook system |
| **[Troubleshooting](https://github.com/ArMaTeC/lxc-to-vm/wiki/Troubleshooting)** | Common issues and solutions |
| **[API & Automation](https://github.com/ArMaTeC/lxc-to-vm/wiki/API-Automation)** | CI/CD integration examples |
| **[Examples](https://github.com/ArMaTeC/lxc-to-vm/wiki/Examples)** | Real-world use cases |

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
├── examples/             # Hook examples for lxc-to-vm
├── examples-vm-to-lxc/   # Hook examples for vm-to-lxc
├── docs/                 # Wiki source files
└── README.md             # This file
```

---

## 🆘 Getting Help

- Check the **[Wiki Documentation](https://github.com/ArMaTeC/lxc-to-vm/wiki)**
- Review **[Troubleshooting Guide](https://github.com/ArMaTeC/lxc-to-vm/wiki/Troubleshooting)**
- View conversion logs: `/var/log/lxc-to-vm.log` or `/var/log/vm-to-lxc.log`
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
