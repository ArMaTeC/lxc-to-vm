% LXC-TO-VM(1) lxc-to-vm 6.0.6

# NAME

lxc-to-vm.sh — Convert Proxmox LXC containers to KVM virtual machines.

# SYNOPSIS

**lxc-to-vm.sh** [*OPTIONS*]

# DESCRIPTION

`lxc-to-vm.sh` converts a Proxmox LXC container into a fully bootable
QEMU/KVM virtual machine. It supports interactive and non-interactive use,
storage conversion, shrinking, snapshots, batch processing, profiles, hooks,
and remote cluster migration.

# OPTIONS

**-c, --ctid** *ID*
: Source LXC container ID.

**-v, --vmid** *ID*
: Target VM ID.

**-s, --storage** *NAME*
: Proxmox storage target (e.g. `local-lvm`).

**-d, --disk-size** *GB*
: Disk size in GB. Omit to use the predictive size advisor.

**-f, --format** *FMT*
: Disk format: `qcow2` (default), `raw`, or `vmdk`.

**-b, --bridge** *NAME*
: Network bridge (default: `vmbr0`).

**-t, --temp-dir** *PATH*
: Working directory for temporary images (default: `/var/lib/vz/dump`).

**-B, --bios** *TYPE*
: Firmware: `seabios` (default) or `ovmf` for UEFI.

**-n, --dry-run**
: Show the planned actions without making changes.

**-k, --keep-network**
: Preserve the original network config and only add an `ens18` adapter.

**-S, --start**
: Auto-start the VM and run health checks after conversion.

**--shrink**
: Shrink the LXC disk to usage plus headroom before converting.

**--snapshot**
: Create an LXC snapshot before conversion for rollback.

**--rollback-on-failure**
: Roll back to the snapshot if conversion fails.

**--destroy-source**
: Destroy the original LXC container after a successful conversion.

**--replace-vm**
: Stop and destroy an existing VM with the target VMID.

**--resume**
: Resume an interrupted conversion from saved state.

**--batch** *FILE*
: Batch file with `CTID,VMID` pairs for mass conversion.

**--range** *START-END:START-END*
: Convert a range of containers to a range of VMs.

**--save-profile** *NAME*
: Save current options as a named profile.

**--profile** *NAME*
: Load options from a saved profile.

**--wizard**
: Start the interactive TUI wizard.

**--parallel** *N*
: Run up to N conversions in parallel in batch mode.

**--validate-only**
: Run pre-flight checks without converting.

**--export-to** *DEST*
: Export the VM disk after conversion (`s3://`, `nfs://`, `ssh://`, or local path).

**--as-template**
: Convert the resulting VM to a Proxmox template.

**--sysprep**
: Clean a template by removing SSH keys, machine-id, etc.

**--api-host** *HOST*
: Proxmox API host for cluster operations.

**--api-token** *TOKEN*
: API token for cluster authentication.

**--api-user** *USER*
: API user (default: `root@pam`).

**--migrate-to-local**
: Auto-migrate the container to the local node if it resides on a remote node.

**--predict-size**
: Use the predictive advisor for disk size based on growth patterns.

**--no-auto-fix**
: Disable automatic remediation when health checks detect known issues.

**-h, --help**
: Show help and exit.

**-V, --version**
: Show version and exit.

# ENVIRONMENT

`LXC_TO_VM_DEBUG`
: Set to `1` to enable verbose debug output and `set -x` tracing.

# FILES

`/var/log/lxc-to-vm.log`
: Operation log.

`/var/lib/lxc-to-vm/hooks/`
: Hook scripts executed at conversion stages.

`/var/lib/lxc-to-vm/profiles/`
: Saved conversion profiles.

`/var/lib/lxc-to-vm/resume/`
: Resume state files for interrupted conversions.

# EXIT STATUS

`0`
: Success.

`1`
: Invalid argument or generic failure.

`2`
: Container or resource not found.

`3`
: Insufficient disk space.

`4`
: Permission denied.

`5`
: Cluster migration failed.

`6`
: Core conversion process failed.

# EXAMPLES

```bash
# Interactive mode
sudo ./lxc-to-vm.sh

# Non-interactive conversion
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm -d 32 --start

# Shrink, snapshot, and auto-start
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --shrink --snapshot --start

# Batch conversion with parallel execution
sudo ./lxc-to-vm.sh --batch conversions.txt --parallel 4
```

# SEE ALSO

`vm-to-lxc.sh(1)`, `shrink-lxc.sh(1)`, `expand-lxc.sh(1)`,
`shrink-vm.sh(1)`, `expand-vm.sh(1)`, `clone-replace-disk.sh(1)`
