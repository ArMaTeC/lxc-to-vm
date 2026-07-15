% VM-TO-LXC(1) lxc-to-vm 6.0.6

# NAME

vm-to-lxc.sh — Convert Proxmox KVM virtual machines to LXC containers.

# SYNOPSIS

**vm-to-lxc.sh** [*OPTIONS*]

# DESCRIPTION

`vm-to-lxc.sh` converts a Proxmox QEMU/KVM virtual machine into an LXC
container. It supports the same automation features as `lxc-to-vm.sh`, including
profiles, hooks, batch processing, snapshots, and API-driven cluster migration.

# OPTIONS

Most options mirror `lxc-to-vm.sh`. Key options:

**-v, --vmid** *ID*
: Source VM ID.

**-c, --ctid** *ID*
: Target LXC container ID.

**-s, --storage** *NAME*
: Proxmox storage target.

**-d, --disk-size** *GB*
: Target container disk size. Omit to use usage-based recommendation.

**-b, --bridge** *NAME*
: Network bridge (default: `vmbr0`).

**-n, --dry-run**
: Preview actions without making changes.

**-S, --start**
: Start the container and run health checks after conversion.

**--snapshot**
: Create a VM snapshot before conversion.

**--rollback-on-failure**
: Roll back to the snapshot if conversion fails.

**--destroy-source**
: Destroy the original VM after a successful conversion.

**--replace-ct**
: Stop and destroy an existing container with the target CTID.

**--resume**
: Resume an interrupted conversion.

**--batch** *FILE*
: Batch file with `VMID,CTID` pairs.

**--range** *START-END:START-END*
: Convert a range of VMs to a range of containers.

**--save-profile** *NAME*, **--profile** *NAME*
: Save or load named option profiles.

**--wizard**
: Start the interactive TUI wizard.

**--parallel** *N*
: Run up to N conversions in parallel in batch mode.

**--validate-only**
: Run pre-flight checks only.

**--api-host** *HOST*, **--api-token** *TOKEN*, **--api-user** *USER*
: Proxmox API credentials for cluster operations.

**--migrate-to-local**
: Auto-migrate the VM to the local node before converting.

**-h, --help**
: Show help and exit.

**-V, --version**
: Show version and exit.

# ENVIRONMENT

`VM_TO_LXC_DEBUG`
: Set to `1` to enable verbose debug output.

# FILES

`/var/log/vm-to-lxc.log`
: Operation log.

`/var/lib/vm-to-lxc/hooks/`
: Hook scripts.

`/var/lib/vm-to-lxc/profiles/`
: Saved profiles.

`/var/lib/vm-to-lxc/resume/`
: Resume state files.

# EXIT STATUS

`0`
: Success.

`1`
: Invalid argument or generic failure.

`2`
: VM or resource not found.

`3`
: Insufficient disk space.

`4`
: Permission denied.

`5`
: Cluster migration failed.

`6`
: Core conversion process failed.

# SEE ALSO

`lxc-to-vm.sh(1)`, `shrink-lxc.sh(1)`, `expand-lxc.sh(1)`,
`shrink-vm.sh(1)`, `expand-vm.sh(1)`, `clone-replace-disk.sh(1)`
