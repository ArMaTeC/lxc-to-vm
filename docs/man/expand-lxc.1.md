% EXPAND-LXC(1) lxc-to-vm 6.0.0

# NAME

expand-lxc.sh — Expand a Proxmox LXC container root disk.

# SYNOPSIS

**expand-lxc.sh** [*OPTIONS*]

# DESCRIPTION

`expand-lxc.sh` grows an LXC container's root disk using one of several
expansion modes. Hot-expand is supported on most storage backends.

# OPTIONS

**-c, --ctid** *ID*
: Container ID to expand.

**-s, --size** *GB*
: Set absolute target size in GiB.

**-a, --add** *GB*
: Add the specified GiB to the current size.

**--percent** *N*
: Expand to N percent of available storage pool capacity.

**--max**
: Use the maximum available space, respecting safety margins.

**--fill-free**
: Deprecated alias for `--max`.

**--safety-margin** *GB*
: Reserve this many GiB when using `--max` (default: 10).

**--safety-percent** *N*
: Reserve this percentage of the pool when using `--max` (default: 5).

**--no-restart**
: Keep the container running where hot-expand is supported.

**--force**
: Skip confirmation prompts.

**-n, --dry-run**
: Preview the expansion plan without making changes.

**-h, --help**
: Show help and exit.

**-V, --version**
: Show version and exit.

# ENVIRONMENT

`EXPAND_LXC_DEBUG`
: Set to `1` to enable verbose debug output.

# FILES

`/var/log/expand-lxc.log`
: Operation log.

# EXAMPLES

```bash
sudo ./expand-lxc.sh -c 100 -s 100
sudo ./expand-lxc.sh -c 100 -a 50
sudo ./expand-lxc.sh -c 100 --max
```

# SEE ALSO

`lxc-to-vm.sh(1)`, `shrink-lxc.sh(1)`, `expand-vm.sh(1)`
