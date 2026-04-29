# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [6.0.7] - 2025-06-01

### Added (Disk Management Suite)

- **`expand-lxc.sh`**: New script to expand LXC container root disk
  - Expansion modes: absolute size (`-s`), add GB (`-a`), percent of pool (`--percent`), max available (`--max`)
  - Hot-expand support (`--no-restart`) for LVM, LVM-thin, ZFS, and raw directory storage
  - Safety margins for `--max` mode (`--safety-margin`, `--safety-percent`)
  - Dry-run mode (`--dry-run`) for change preview
  - Structured exit codes and mapped error messages
  - Debug mode via `EXPAND_LXC_DEBUG=1`, log at `/var/log/expand-lxc.log`

- **`expand-vm.sh`**: New script to expand VM primary disk
  - Same expansion modes as `expand-lxc.sh`
  - Hot-expand support (`--hot-expand`) via QEMU monitor (`block_resize`)
  - Supports QCOW2 and raw image formats
  - Dry-run mode (`--dry-run`) for change preview
  - Structured exit codes and mapped error messages
  - Debug mode via `EXPAND_VM_DEBUG=1`, log at `/var/log/expand-vm.log`

- **`shrink-vm.sh`**: New script to shrink VM disk to actual usage
  - Measures real data usage via `virt-df` (libguestfs) or `qemu-img`
  - Optional `virt-resize` path (`-u`/`--use-libguestfs`) for complex layouts
  - Configurable headroom (`-g`, default 2GB) and metadata margin (5%, min 512MB)
  - Minimum disk size enforced (2GB)
  - Dry-run mode (`--dry-run`) for change preview
  - Supports LVM-thin, LVM, Directory (QCOW2/raw), ZFS
  - Debug mode via `SHRINK_VM_DEBUG=1`, log at `/var/log/shrink-vm.log`

- **`clone-replace-disk.sh`**: New script to clone and replace VM/LXC disks
  - Supports both VM (`-t vm`) and LXC (`-t lxc`) targets
  - Optional resize during clone (`--size`)
  - Cross-storage cloning (e.g., LVM-thin → ZFS, Directory → LVM-thin)
  - Format conversion during clone (`--format raw|qcow2`)
  - Original disk kept by default; removed only with `--remove-old`
  - Optional VM snapshot before operations (`--snapshot`)
  - Automatic rollback of config on clone/replace failure
  - Debug mode via `CLONE_REPLACE_DEBUG=1`, log at `/var/log/clone-replace-disk.log`

### Added (Documentation)

- `docs/expand-lxc.md` — Full reference guide for `expand-lxc.sh`
- `docs/expand-vm.md` — Full reference guide for `expand-vm.sh`
- `docs/shrink-vm.md` — Full reference guide for `shrink-vm.sh`
- `docs/clone-replace-disk.md` — Full reference guide for `clone-replace-disk.sh`
- Updated `docs/Home.md`, `docs/_Sidebar.md`, `docs/Installation.md` to cover all 7 scripts
- Updated `docs/Troubleshooting.md` with sections for all new scripts and debug table
- Updated `docs/API-Automation.md` with automation examples for disk management scripts

---

## [6.0.6] - 2025-02-26

### Fixed (CentOS 7 Support)

- **CentOS 7 EOL repos**: Auto-fix CentOS 7 repos to use vault.centos.org after EOL (June 2024)
- **CentOS 7 GRUB**: Fix linuxefi/initrdefi commands in grub.cfg for BIOS boot
- **pcspkr blacklist**: Add module_blacklist=pcspkr kernel parameter to suppress PC speaker driver errors during boot

## [6.0.5] - 2025-02-25

### Fixed (CentOS/RHEL Support)

- **CPU type fix**: Added `--cpu host` to `qm create` for x86-64-v2 compatibility (CentOS 9 glibc requires x86-64-v2, not supported by default kvm64)
- **Initramfs drivers**: Added `sd_mod` and `ext4` to dracut `--add-drivers` so root block device is created properly
- **LXC artifact cleanup**: Remove LXC-specific systemd generators, container-getty services, and masked mount units that break VM boot
- **Library cache**: Run `ldconfig` before `dracut` so `libsystemd-core` is found and included in initramfs
- **Login prompt**: Enable `getty@tty1` and `serial-getty@ttyS0` services (containers use container-getty which doesn't work in VMs)
- **Guest agent**: Comment out restrictive `FILTER_RPC_ARGS` allow-list in CentOS qemu-ga config so `guest-exec` works

### Fixed (General)

- PowerShell 5.1 compatibility: Use `$psi.Arguments` string instead of `.ArgumentList` collection in `Invoke-ExternalCommandWithTimeout`
- CRLF stripping after SCP to remote host for bash script compatibility

## [6.0.4] - 2025-02-22

### Added

- Added missing `dump_system_info` function for debug output
- Added PayPal donation link for project support

### Fixed

- Fixed ShellCheck warnings with proper exclusions (SC2155, SC2046, SC2221, SC2222, SC2064)
- Fixed missing `LOG_FILE` variable definition
- Fixed missing `debug` function implementation
- Removed duplicate `dump_system_info` call and relocated after function definition
- Removed stray `return` statement outside function scope causing script exit before VM import

## [6.0.3] - 2025-10-22

Added

- Enhanced debug output with detailed phase comments
- GitHub workflows for release, shellcheck, and bash-syntax checks
- Buy Me A Coffee support section

Fixed

- FEATURE_C12 ext4 boot error fixes
- ext4 metadata_csum disabling at mkfs.ext4 creation time
- Filesystem writability test before import
- Host-side BIOS grub-install fallback for loop device errors
- Ownership normalization for unprivileged LXC ID remapping

## [6.0.2] - 2025-10-16

Fixed

- Fixed FEATURE_C12 boot error on older kernels
- Fixed cleanup trap for better resource management
- Metadata_csum feature disabled to prevent busybox initramfs boot failures

## [6.0.1] - 2025-02-12

Added

- API/cluster integration for remote Proxmox operations
- Plugin/hook system for extensibility
- Predictive disk size advisor based on historical growth patterns
- Code standardization across all scripts

Enhanced

- Batch conversion documentation with detailed examples
- Function extraction and code organization improvements

## [6.0.0] - 2025-02-11

Added (Enterprise Edition)

- 🧙 Wizard mode - Interactive TUI with progress bars
- ⚡ Parallel batch processing - Run N conversions concurrently
- ✅ Pre-flight validation - Check container readiness without converting
- ☁️ Cloud/remote storage export - Export to S3, NFS, or SSH destinations
- 📋 VM template creation - Convert directly to Proxmox templates
- 🔄 Resume capability - Resume interrupted conversions
- 🗑️ Auto-destroy source - Clean up original LXC after successful conversion
- 💾 Snapshot & rollback - Automatic rollback on failure
- 📊 Configuration profiles - Save and reuse common settings

Enhanced

- Disk space management with auto-selection of mount points
- Post-conversion validation with 6-point check
- GitHub workflows for automated testing

## [5.1.0] - 2025-02-10

Added

- Auto-retry logic for resize2fs failures (up to 5 attempts)
- 3GB overhead to auto-calculated disk size
- Enhanced workspace logging improvements

Fixed

- Disk space check function organization
- Better error handling during shrink operations

## [5.0.0] - 2025-02-10

Added

- `--shrink` flag for automatic disk shrinking before conversion
- Intelligent sizing with metadata margin calculation
- Integrated shrink + convert workflow

## [4.0.0] - 2025-02-10

Added

- Multi-distro support (Debian, Ubuntu, Alpine, CentOS/RHEL/Rocky, Arch)
- UEFI/OVMF boot support with `--bios ovmf`
- Dry-run mode for previewing conversions
- Enhanced VM configuration options
- Improved argument parsing
- Better error handling and logging

## [1.0.0] - 2025-02-10

Added

- Initial release of lxc-to-vm.sh
- Basic LXC to VM conversion functionality
- Debian/Ubuntu primary support
- BIOS/SeaBIOS boot support
- GRUB2 bootloader injection via chroot
- Network configuration migration (eth0 → ens18)

---

## Legend

- 🆕 **Added** for new features
- 🔧 **Fixed** for bug fixes
- ⚡ **Enhanced** for improvements to existing features
- 🧙 **Added** for wizard/enterprise features
