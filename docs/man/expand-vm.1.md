% EXPAND-VM(1) lxc-to-vm 6.0.6

# NAME

expand-vm.sh — Expand a Proxmox KVM virtual machine disk.

# SYNOPSIS

**expand-vm.sh** [*OPTIONS*]

# DESCRIPTION

`expand-vm.sh` grows a VM disk to an absolute or additive target size. It
supports Linux and Windows guests and multiple storage backends.

# OPTIONS

**-v, --vmid** *ID*
: VM ID to expand.

**-s, --size** *GB*
: Set absolute target size in GiB.

**-a, --add** *GB*
: Add the specified GiB to the current size.

**-n, --dry-run**
: Preview actions without making changes.

**-h, --help**
: Show help and exit.

**-V, --version**
: Show version and exit.

# ENVIRONMENT

`EXPAND_VM_DEBUG`
: Set to `1` to enable verbose debug output.

# FILES

`/var/log/expand-vm.log`
: Operation log.

# EXAMPLES

```bash
sudo ./expand-vm.sh -v 200 -s 200
sudo ./expand-vm.sh -v 200 -a 50
sudo ./expand-vm.sh -v 200 --dry-run
```

# SEE ALSO

`lxc-to-vm.sh(1)`, `shrink-vm.sh(1)`, `expand-lxc.sh(1)`,
`clone-replace-disk.sh(1)`
