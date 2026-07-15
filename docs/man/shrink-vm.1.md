% SHRINK-VM(1) lxc-to-vm 6.0.6

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
: VM ID to shrink.

**-g, --headroom** *GB*
: Extra headroom above used space in GiB.

**-n, --dry-run**
: Preview actions without making changes.

**-h, --help**
: Show help and exit.

**-V, --version**
: Show version and exit.

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
```

# SEE ALSO

`lxc-to-vm.sh(1)`, `expand-vm.sh(1)`, `shrink-lxc.sh(1)`,
`clone-replace-disk.sh(1)`
