<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: shrink-lxc.1.md
     Description: Shrink lxc.1
     License: MIT
     ============================================================================== -->
<!-- markdownlint-disable MD041 -->
% SHRINK-LXC(1) lxc-to-vm 6.2.1

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
: Container ID(s) to shrink. Repeat the flag or give a comma/space-separated
  list (e.g., `-c 100,101,102`). Bare numeric arguments are also accepted.

**-g, --headroom** *GB*
: Extra headroom above used space in GiB (default: 1).

**-n, --dry-run**
: Show what would be done without making changes.

**-y, --yes**
: Non-interactive mode: auto-accept confirmations. Issues requiring
  attention are still reported and abort that container; in batch mode
  processing continues with the next ID.

**-h, --help**
: Show help and exit.

**-V, --version**
: Show version and exit.

# EXIT STATUS

`0` on success; `1` invalid arguments; `2` not found; `5` shrink failed
(also returned in batch mode when any container failed); `10` aborted by user.

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
sudo ./shrink-lxc.sh -c 100,101,102 -y
```

# SEE ALSO

`lxc-to-vm.sh(1)`, `expand-lxc.sh(1)`, `shrink-vm.sh(1)`
