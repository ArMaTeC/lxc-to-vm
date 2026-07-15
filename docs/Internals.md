<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: Internals.md
     Description: Internal architecture, data flow, and development guide
     License: MIT
     ============================================================================== -->

# Internals & Developer Guide

This document describes the internal architecture, conventions, and extension
points of the `lxc-to-vm` toolkit for contributors and advanced users.

---

## Project Layout

```
lxc-to-vm/
├── lxc-to-vm.sh           # Main LXC → VM converter
├── vm-to-lxc.sh           # Main VM → LXC converter
├── shrink-lxc.sh          # Shrink LXC root disk
├── expand-lxc.sh          # Expand LXC root disk
├── shrink-vm.sh           # Shrink VM disk
├── expand-vm.sh           # Expand VM disk
├── clone-replace-disk.sh  # Clone/replace VM or LXC disks
├── add-file-headers.sh    # Repository maintenance: standardized headers
├── test-remote-pve.sh     # Remote PVE smoke-test harness
├── lib/
│   ├── common.sh          # Shared helpers (library sourcing)
│   ├── os-detect.sh       # OS/boot-mode detection from disk images
│   └── windows-disk.sh    # Windows NTFS disk operations
├── docs/                  # Markdown documentation
└── examples/              # Example hooks, profiles, and batch files
```

All shell scripts use `set -Eeuo pipefail` and run under `bash`.

---

## Coding Conventions

### File Headers

Every tracked file includes a standardized header block managed by
`add-file-headers.sh`:

```bash
# ==============================================================================
# ### lxc-to-vm file header ###
# File: <filename>
# Description: <short summary>
# License: MIT
# ==============================================================================
```

Run `./add-file-headers.sh` after adding new files to keep headers consistent.

### Function Documentation

Reusable functions use a consistent header comment:

```bash
### Function: <name>
# <One-line summary>
#
# Arguments:
#   $1 - <description>
#
# Globals:
#   <VAR> - <description>
#
# Outputs:
#   <description>
#
# Returns:
#   <exit code semantics>
```

Logging helpers and trivial one-liners are documented inline where helpful.

### Naming

- Public functions: lowercase with underscores (`detect_os_from_disk`).
- Internal helpers: leading underscore (`_detect_via_guestfs`).
- Constants: `UPPER_CASE` and `readonly` where possible.
- Exit-code constants: prefixed with `E_`.

### Error Handling

- `set -Eeuo pipefail` enables strict mode.
- An `ERR` trap (`on_error`) maps failures to stable exit codes and prints
  actionable diagnostics.
- `cleanup()` is registered on `EXIT`, `INT`, and `TERM` to release mounts,
  loop devices, and temporary directories.

---

## LXC → VM Conversion Flow (`lxc-to-vm.sh`)

```
Input validation
      │
      ▼
Pre-flight checks (dependencies, storage, VMID conflict)
      │
      ▼
Optional: migrate container to local node
      │
      ▼
Optional: shrink LXC root disk (shrink-lxc.sh logic inline)
      │
      ▼
Create raw disk image in temp work dir
      │
      ▼
Mount source container rootfs via pct mount or loopback
      │
      ▼
Sync filesystem into disk image (rsync)
      │
      ▼
Install bootloader / kernel / initramfs per detected distro
      │
      ▼
Configure network adapter (ens18), bootloader, fstab
      │
      ▼
Import disk into Proxmox storage and attach to new VM
      │
      ▼
Post-conversion health checks
      │
      ▼
Optional: start VM, export disk, convert to template, destroy source
```

Key phases are instrumented with `run_hook` so users can inject custom logic.

---

## VM → LXC Conversion Flow (`vm-to-lxc.sh`)

```
Input validation
      │
      ▼
Pre-flight checks
      │
      ▼
Optional: migrate VM to local node
      │
      ▼
Create target LXC container skeleton
      │
      ▼
Export / map VM disk
      │
      ▼
Mount VM rootfs and copy into container rootfs
      │
      ▼
Adapt configuration for container (network, fstab, services)
      │
      ▼
Set container resources and start / validate
      │
      ▼
Optional: destroy source VM
```

---

## Disk Operation Architecture

The disk utilities share a common pattern:

1. **Stop** the guest (LXC/VM) when required by the storage backend.
2. **Detect** storage type via `pct config` / `qm config` + `pvesm status`.
3. **Map** the underlying volume/image:
   - LVM/LVM-thin → `/dev/mapper/...` LV path
   - ZFS → `/dev/zd*` zvol
   - Directory → raw/qcow2 image file
4. **Resize** the filesystem or image using backend-appropriate tools
   (`resize2fs`, `e2fsck`, `qemu-img resize`, `lvresize`, `zfs set volsize`).
5. **Update** Proxmox configuration (`pct set`, `qm set`).
6. **Restart** the guest if it was running.

Windows disks are routed through `lib/windows-disk.sh`, which uses `libguestfs`
when available and falls back to `ntfsfix`/`ntfsresize`.

---

## OS Detection

`lib/os-detect.sh` inspects a disk image and sets several globals:

| Global | Values |
|--------|--------|
| `OS_TYPE` | `windows`, `linux`, `unknown` |
| `OS_DISTRO` | Distribution hint or `unknown` |
| `OS_VERSION` | Version string when available |
| `OS_BOOT_MODE` | `uefi`, `bios`, `unknown` |
| `OS_PARTITION_TABLE` | `gpt`, `mbr`, `unknown` |
| `OS_HAS_ESP` | `true`, `false` |

The detector first tries `virt-inspector` (most reliable). If unavailable, it
falls back to `fdisk`/`parted` partition-table heuristics and `file` signatures.

---

## Hook System

Hooks are executable scripts placed in:

- `/var/lib/lxc-to-vm/hooks/` for `lxc-to-vm.sh`
- `/var/lib/vm-to-lxc/hooks/` for `vm-to-lxc.sh`

Hook files are named by stage. Each hook receives the source and target IDs as
positional arguments and the following environment variables:

| Variable | Meaning |
|----------|---------|
| `HOOK_CTID` | Source/target container ID |
| `HOOK_VMID` | Source/target VM ID |
| `HOOK_STAGE` | Stage name |
| `HOOK_LOG_FILE` | Log file path |

Common stages: `pre-shrink`, `post-shrink`, `pre-convert`, `post-convert`,
`health-check-failed`, `pre-destroy`.

Hooks are non-fatal by design; a failing hook logs a warning but does not stop
the conversion.

---

## Resume / State Persistence

Long-running conversions can be interrupted. `lxc-to-vm.sh` and `vm-to-lxc.sh`
write resume state to:

- `/var/lib/lxc-to-vm/resume/`
- `/var/lib/vm-to-lxc/resume/`

Resume files are named `ct<CTID>-vm<VMID>.state` or `vm<VMID>-ct<CTID>.state`
and store stage, timestamp, temp directory, and metadata. Pass `--resume` to
continue from the last saved stage.

---

## Profile System

Named profiles store common option sets in `/var/lib/lxc-to-vm/profiles/` or
`/var/lib/vm-to-lxc/profiles/`. A profile is a simple `source`-able file of
`KEY="value"` assignments. Use `--save-profile <name>` and `--profile <name>`.

---

## API & Cluster Integration

Both main scripts can call the Proxmox VE API when `--api-host` and
`--api-token` are supplied:

- Locate resources across cluster nodes (`get_cluster_info`).
- Migrate guests to the local node before conversion (`migrate_*_to_local`).
- Issue arbitrary API calls via `pve_api_call`.

Token format: `API_TOKEN="<user>!<token-name>=<secret>"`.

---

## Adding a New Script

1. Create the script in the repository root with a `#!/bin/bash` shebang.
2. Use `set -Eeuo pipefail`.
3. Include the standardized file header.
4. Add logging helpers (or source `lib/common.sh` and reuse shared helpers).
5. Register `trap cleanup EXIT INT TERM` for resource cleanup.
6. Document new public functions in `docs/Function-Reference.md`.
7. Run `./add-file-headers.sh` to update headers across the repository.
8. Validate syntax with `bash -n <script>`.

---

## Testing

- **Syntax**: `bash -n *.sh lib/*.sh`
- **Static analysis**: [ShellCheck](https://www.shellcheck.net/) via
  `.github/workflows/shellcheck.yml`
- **Remote smoke tests**: `test-remote-pve.sh` uploads scripts and exercises
  conversion flows against a remote Proxmox VE host.

---

## Common Extension Points

| Task | Where to add |
|------|--------------|
| New distro support | `lxc-to-vm.sh` bootloader/initramfs sections; `lib/os-detect.sh` |
| New storage backend | `shrink-lxc.sh`, `expand-lxc.sh`, `shrink-vm.sh`, `expand-vm.sh` case blocks |
| New conversion hook stage | `run_hook()` calls in `lxc-to-vm.sh` / `vm-to-lxc.sh` |
| New disk format | `lxc-to-vm.sh` import path; `vm-to-lxc.sh` export path |
