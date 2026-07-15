<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: Documentation-Coverage.md
     Description: Documentation coverage summary for the lxc-to-vm project
     License: MIT
     ============================================================================== -->

# Documentation Coverage Summary

Generated during the documentation pass for the `lxc-to-vm` project.

## New and Updated Documentation

| File | Purpose |
|------|---------|
| `README.md` | Updated with a documentation index linking to all new guides. |
| `docs/Function-Reference.md` | Complete function reference grouped by source file. |
| `docs/Internals.md` | Architecture, data flow, conventions, and contributor guide. |
| `docs/man/README.md` | Instructions for building and viewing man pages. |
| `docs/man/lxc-to-vm.1.md` | Man page source for the main LXC→VM converter. |
| `docs/man/vm-to-lxc.1.md` | Man page source for the VM→LXC converter. |
| `docs/man/shrink-lxc.1.md` | Man page source for `shrink-lxc.sh`. |
| `docs/man/expand-lxc.1.md` | Man page source for `expand-lxc.sh`. |
| `docs/man/shrink-vm.1.md` | Man page source for `shrink-vm.sh`. |
| `docs/man/expand-vm.1.md` | Man page source for `expand-vm.sh`. |
| `docs/man/clone-replace-disk.1.md` | Man page source for `clone-replace-disk.sh`. |

## Inline Function Header Coverage

The table below counts functions per file and the number that now carry a
standardized `### Function: <name>` header comment.

| File | Functions | Documented | Coverage |
|------|-----------|------------|----------|
| `lxc-to-vm.sh` | 54 | 37 | 68.5% |
| `vm-to-lxc.sh` | 45 | 22 | 48.9% |
| `shrink-lxc.sh` | 12 | 11 | 91.7% |
| `expand-lxc.sh` | 15 | 12 | 80.0% |
| `shrink-vm.sh` | 12 | 12 | 100% |
| `expand-vm.sh` | 15 | 12 | 80.0% |
| `clone-replace-disk.sh` | 12 | 12 | 100% |
| `add-file-headers.sh` | 10 | 9 | 90.0% |
| `test-remote-pve.sh` | 2 | 2 | 100% |
| `lib/common.sh` | 1 | 1 | 100% |
| `lib/os-detect.sh` | 3 | 3 | 100% |
| `lib/windows-disk.sh` | 6 | 6 | 100% |
| **Total** | **187** | **139** | **74.3%** |

### Notes on Coverage

- Library files and standalone utility scripts achieved near-complete coverage.
- The two main conversion scripts (`lxc-to-vm.sh` and `vm-to-lxc.sh`) contain
  many large procedural helpers (distro-specific bootloader setup, GRUB/EFI
  configuration, network adapter injection, etc.) that are documented in
  `docs/Function-Reference.md` even when they do not yet carry an inline header.
- Remaining undocumented functions are mostly one-off distro branches or
  sequential UI prompts inside the TUI wizard.

## Validation

Syntax validation is intended to be run on a Linux host with `bash`:

```bash
cd /path/to/lxc-to-vm
bash -n lxc-to-vm.sh vm-to-lxc.sh \
  shrink-lxc.sh expand-lxc.sh \
  shrink-vm.sh expand-vm.sh \
  clone-replace-disk.sh add-file-headers.sh \
  test-remote-pve.sh \
  lib/common.sh lib/os-detect.sh lib/windows-disk.sh
```

If available, also run ShellCheck:

```bash
shellcheck lxc-to-vm.sh vm-to-lxc.sh shrink-lxc.sh expand-lxc.sh \
  shrink-vm.sh expand-vm.sh clone-replace-disk.sh add-file-headers.sh \
  test-remote-pve.sh lib/*.sh
```

> Note: The Windows environment used for this documentation pass does not
> include `bash` or `shellcheck`, so these commands were not executed here and
> should be run on a Linux/macOS host or WSL before committing.

## Building Man Pages

The man page sources are Markdown. Render them to troff with Pandoc:

```bash
mkdir -p man1
pandoc docs/man/lxc-to-vm.1.md -s -t man -o man1/lxc-to-vm.1
pandoc docs/man/vm-to-lxc.1.md -s -t man -o man1/vm-to-lxc.1
pandoc docs/man/shrink-lxc.1.md -s -t man -o man1/shrink-lxc.1
pandoc docs/man/expand-lxc.1.md -s -t man -o man1/expand-lxc.1
pandoc docs/man/shrink-vm.1.md -s -t man -o man1/shrink-vm.1
pandoc docs/man/expand-vm.1.md -s -t man -o man1/expand-vm.1
pandoc docs/man/clone-replace-disk.1.md -s -t man -o man1/clone-replace-disk.1
```

Install locally for testing:

```bash
mkdir -p ~/.local/share/man/man1
cp man1/*.1 ~/.local/share/man/man1/
man lxc-to-vm
```
