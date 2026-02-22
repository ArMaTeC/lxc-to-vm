# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

### Added
- Enhanced debug output with detailed phase comments
- GitHub workflows for release, shellcheck, and bash-syntax checks
- Buy Me A Coffee support section

### Fixed
- FEATURE_C12 ext4 boot error fixes
- ext4 metadata_csum disabling at mkfs.ext4 creation time
- Filesystem writability test before import
- Host-side BIOS grub-install fallback for loop device errors
- Ownership normalization for unprivileged LXC ID remapping

## [6.0.2] - 2025-10-16

### Fixed
- Fixed FEATURE_C12 boot error on older kernels
- Fixed cleanup trap for better resource management
- Metadata_csum feature disabled to prevent busybox initramfs boot failures

## [6.0.1] - 2025-02-12

### Added
- API/cluster integration for remote Proxmox operations
- Plugin/hook system for extensibility
- Predictive disk size advisor based on historical growth patterns
- Code standardization across all scripts

### Enhanced
- Batch conversion documentation with detailed examples
- Function extraction and code organization improvements

## [6.0.0] - 2025-02-11

### Added (Enterprise Edition)
- 🧙 Wizard mode - Interactive TUI with progress bars
- ⚡ Parallel batch processing - Run N conversions concurrently
- ✅ Pre-flight validation - Check container readiness without converting
- ☁️ Cloud/remote storage export - Export to S3, NFS, or SSH destinations
- 📋 VM template creation - Convert directly to Proxmox templates
- 🔄 Resume capability - Resume interrupted conversions
- 🗑️ Auto-destroy source - Clean up original LXC after successful conversion
- 💾 Snapshot & rollback - Automatic rollback on failure
- 📊 Configuration profiles - Save and reuse common settings

### Enhanced
- Disk space management with auto-selection of mount points
- Post-conversion validation with 6-point check
- GitHub workflows for automated testing

## [5.1.0] - 2025-02-10

### Added
- Auto-retry logic for resize2fs failures (up to 5 attempts)
- 3GB overhead to auto-calculated disk size
- Enhanced workspace logging improvements

### Fixed
- Disk space check function organization
- Better error handling during shrink operations

## [5.0.0] - 2025-02-10

### Added
- `--shrink` flag for automatic disk shrinking before conversion
- Intelligent sizing with metadata margin calculation
- Integrated shrink + convert workflow

## [4.0.0] - 2025-02-10

### Added
- Multi-distro support (Debian, Ubuntu, Alpine, CentOS/RHEL/Rocky, Arch)
- UEFI/OVMF boot support with `--bios ovmf`
- Dry-run mode for previewing conversions
- Enhanced VM configuration options
- Improved argument parsing
- Better error handling and logging

## [1.0.0] - 2025-02-10

### Added
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
