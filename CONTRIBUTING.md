# Contributing to lxc-to-vm

Thanks for your interest in contributing! Here's how to get started.

## Reporting Bugs

1. Check [existing issues](https://github.com/ArMaTeC/lxc-to-vm/issues) first.
2. Open a new issue with:
   - Proxmox VE version (`pveversion -v`)
   - Source LXC OS / VM OS (e.g., Debian 12, Ubuntu 22.04)
   - Full error output
   - Relevant log entries from the script's log file:
     - `lxc-to-vm.sh` → `/var/log/lxc-to-vm.log`
     - `vm-to-lxc.sh` → `/var/log/vm-to-lxc.log`
     - `shrink-lxc.sh` → `/var/log/shrink-lxc.log`
     - `expand-lxc.sh` → `/var/log/expand-lxc.log`
     - `shrink-vm.sh` → `/var/log/shrink-vm.log`
     - `expand-vm.sh` → `/var/log/expand-vm.log`
     - `clone-replace-disk.sh` → `/var/log/clone-replace-disk.log`

## Suggesting Features

Open an issue tagged `enhancement` describing the use case and expected behavior.

## Submitting Changes

### Setup

```bash
git clone https://github.com/ArMaTeC/lxc-to-vm.git
cd lxc-to-vm
git checkout -b feature/my-change
```

### Code Standards

- **Shell:** Bash 4.x+ (`#!/usr/bin/env bash`)
- **Style:** Follow existing conventions in the script
- **Linting:** All changes must pass ShellCheck with zero warnings for the modified script(s):

  ```bash
  shellcheck --severity=warning --shell=bash lxc-to-vm.sh
  shellcheck --severity=warning --shell=bash vm-to-lxc.sh
  shellcheck --severity=warning --shell=bash shrink-lxc.sh
  shellcheck --severity=warning --shell=bash expand-lxc.sh
  shellcheck --severity=warning --shell=bash shrink-vm.sh
  shellcheck --severity=warning --shell=bash expand-vm.sh
  shellcheck --severity=warning --shell=bash clone-replace-disk.sh
  # Or check all at once:
  shellcheck --severity=warning --shell=bash *.sh
  ```

- **Quoting:** Always double-quote variable expansions (`"$VAR"`, not `$VAR`)
- **Error handling:** Use `set -euo pipefail`; use the `die()` function for fatal errors

### Pull Request Process

1. Ensure ShellCheck passes locally for all modified scripts.
2. Update `README.md` if you add new flags or change behavior.
3. Update the relevant `docs/<script-name>.md` if the script's interface changes.
4. Bump the `VERSION` variable in the modified script(s) if applicable.
5. Add a `CHANGELOG.md` entry under a new version heading.
6. Open a PR against the `main` branch with a clear description.

### Commit Messages

Use clear, imperative-mood messages:

```bash
Add --format flag for disk image format selection
Fix cleanup trap not detaching loop device on error
```

## Releases

Releases are automated via GitHub Actions when a version tag is pushed:

```bash
git tag v3.1.0
git push origin v3.1.0
```

## Code of Conduct

Be respectful. Constructive feedback only. We're all here to make Proxmox workflows easier.
