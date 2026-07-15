% SHRINK-LXC(1) lxc-to-vm 6.0.6

# NAME

shrink-lxc.sh — Shrink a Proxmox LXC container root disk to actual usage.

# SYNOPSIS

**shrink-lxc.sh** [*OPTIONS*]

# DESCRIPTION

`shrink-lxc.sh` reduces an LXC container's root disk to the space currently used
plus configurable headroom. This is useful before converting the container to a
VM with `lxc-to-vm.sh`.

# OPTIONS

**-c, --ctid** *ID*
: Container ID to shrink.

**-g, --headroom** *GB*
: Extra headroom above used space in GiB (default: 1).

**-n, --dry-run**
: Show what would be done without making changes.

**-h, --help**
: Show help and exit.

**-V, --version**
: Show version and exit.

# STORAGE SUPPORT

- **LVM-thin**: Shrinks the LV directly.
- **Directory**: Supports raw and qcow2 images.
- **ZFS**: Shrinks the zvol size.
- **NFS/CIFS**: Treated as directory storage.

# ENVIRONMENT

`SHRINK_LXC_DEBUG`
: Set to `1` to enable verbose debug output.

# FILES

`/var/log/shrink-lxc.log`
: Operation log.

# EXAMPLES

```bash
sudo ./shrink-lxc.sh -c 100
sudo ./shrink-lxc.sh -c 100 -g 2
sudo ./shrink-lxc.sh -c 100 --dry-run
```

# SEE ALSO

`lxc-to-vm.sh(1)`, `expand-lxc.sh(1)`, `shrink-vm.sh(1)`
