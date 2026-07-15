% CLONE-REPLACE-DISK(1) lxc-to-vm 6.0.6

# NAME

clone-replace-disk.sh — Clone and replace a Proxmox VM or LXC disk.

# SYNOPSIS

**clone-replace-disk.sh** [*OPTIONS*]

# DESCRIPTION

`clone-replace-disk.sh` clones a guest disk to a new image and optionally
replaces the original disk reference in the VM or LXC configuration. It is useful
for storage migration or resizing operations.

# OPTIONS

**-s, --source** *PATH*
: Source disk path.

**-t, --target** *PATH*
: Target disk path.

**-v, --vmid** *ID*
: VM ID to update after cloning.

**-c, --ctid** *ID*
: Container ID to update after cloning.

**--disk** *N*
: Disk index to replace (e.g., `scsi0`, `ide0`, or `mp0`).

**--new-size** *GB*
: Optional target size in GiB.

**-n, --dry-run**
: Preview actions without making changes.

**-h, --help**
: Show help and exit.

**-V, --version**
: Show version and exit.

# ENVIRONMENT

`CLONE_REPLACE_DEBUG`
: Set to `1` to enable verbose debug output.

# FILES

`/var/log/clone-replace-disk.log`
: Operation log.

# EXAMPLES

```bash
sudo ./clone-replace-disk.sh -s /path/to/source.raw -t /path/to/target.qcow2
sudo ./clone-replace-disk.sh -v 200 --disk scsi0 -s source.qcow2 -t target.qcow2 --new-size 100
```

# SEE ALSO

`shrink-vm.sh(1)`, `expand-vm.sh(1)`, `lxc-to-vm.sh(1)`, `vm-to-lxc.sh(1)`
