<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: shrink-vm.1.md
     Description: Shrink vm.1
     License: MIT
     ============================================================================== -->
<!-- markdownlint-disable MD041 -->
% SHRINK-VM(1) lxc-to-vm 6.2.1

# NAME

shrink-vm.sh — Shrink a Proxmox KVM virtual machine disk to actual usage.

# SYNOPSIS

**shrink-vm.sh** [*OPTIONS*]

# DESCRIPTION

`shrink-vm.sh` reduces a VM disk to the filesystem usage plus headroom. It
handles Linux guests with `resize2fs`/`e2fsck` and Windows guests via
`lib/windows-disk.sh` using `libguestfs` or `ntfsresize`.

# OPTIONS

**-v, --vmid** *ID*
: VM ID(s) to shrink. Repeat the flag or give a comma/space-separated list
  (e.g., `-v 100,101,102`). Bare numeric arguments are also accepted.

**-g, --headroom** *GB*
: Extra headroom above used space in GiB.

**-n, --dry-run**
: Preview actions without making changes.

**-u, --use-libguestfs**
: Use `virt-resize`/libguestfs (more reliable, slower).

**--skip-fs-check**
: Skip filesystem checks (not recommended).

**--force**
: Override the Windows 30 GiB minimum size enforcement.

**--os-type** *TYPE*
: Override OS detection (`linux`, `windows`).

**-y, --yes**
: Non-interactive mode: auto-accept confirmations. Issues requiring
  attention are still reported and abort that VM; in batch mode processing
  continues with the next ID.

**-t, --temp-dir** *PATH*
: Directory for temporary raw images during qcow2/libguestfs shrinks
  (default: `/var/tmp`). Needs free space >= the disk's virtual size.

**-h, --help**
: Show help and exit.

**-V, --version**
: Show version and exit.

# EXIT STATUS

`0` on success; `1` invalid arguments; `2` not found; `5` shrink failed
(also returned in batch mode when any VM failed); `10` aborted by user.

# ENVIRONMENT

`SHRINK_VM_DEBUG`
: Set to `1` to enable verbose debug output.

# FILES

`/var/log/shrink-vm.log`
: Operation log.

# EXAMPLES

```bash
sudo ./shrink-vm.sh -v 200
sudo ./shrink-vm.sh -v 200 -g 5
sudo ./shrink-vm.sh -v 200 --dry-run
sudo ./shrink-vm.sh -v 200,201,202 -y
```

# SEE ALSO

`lxc-to-vm.sh(1)`, `expand-vm.sh(1)`, `shrink-lxc.sh(1)`,
`clone-replace-disk.sh(1)`
