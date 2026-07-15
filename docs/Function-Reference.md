<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: Function-Reference.md
     Description: Complete function reference for all shell scripts and libraries
     License: MIT
     ============================================================================== -->

# Function Reference

This document provides a complete reference of every shell function defined in
the `lxc-to-vm` toolkit. Functions are grouped by source file and ordered by
appearance in the file.

- **[Library Functions](#library-functions)** – Reusable helpers in `lib/`
- **[Main Conversion Scripts](#main-conversion-scripts)** – `lxc-to-vm.sh`, `vm-to-lxc.sh`
- **[Disk Utility Scripts](#disk-utility-scripts)** – shrink/expand/clone helpers
- **[Utility Scripts](#utility-scripts)** – Testing and maintenance helpers

---

## Library Functions

### `lib/common.sh`

#### `lib_source`

| | |
|---|---|
| **Signature** | `lib_source <lib_name>` |
| **Purpose** | Source a sibling library from the same directory by filename. |
| **Arguments** | `$1` — Name of the library file to source (e.g., `os-detect.sh`). |
| **Outputs** | Error message to `stderr` if the library is missing. |
| **Returns** | `0` on success; exits with `1` if the library file is not found. |

---

### `lib/os-detect.sh`

Detects the operating system installed on a disk image by trying `virt-inspector`
first and falling back to partition-table heuristics.

#### `detect_os_from_disk`

| | |
|---|---|
| **Signature** | `detect_os_from_disk <disk_path> [img_format]` |
| **Purpose** | Detect the operating system installed on a disk image. |
| **Arguments** | `$1` — Path to the disk image to inspect.<br>`$2` — Disk image format (default: `raw`). |
| **Globals set** | `OS_TYPE`, `OS_DISTRO`, `OS_VERSION`, `OS_BOOT_MODE`, `OS_PARTITION_TABLE`, `OS_HAS_ESP` |
| **Returns** | `0` if detection succeeded; `1` if the OS could not be identified. |

#### `_detect_via_guestfs`

Internal helper that parses `virt-inspector` XML output.

| | |
|---|---|
| **Signature** | `_detect_via_guestfs <disk_path> [img_format]` |
| **Purpose** | Detect OS details using `virt-inspector` (libguestfs). |
| **Globals set** | `OS_TYPE`, `OS_DISTRO`, `OS_VERSION`, `OS_BOOT_MODE`, `OS_PARTITION_TABLE`, `OS_HAS_ESP` |
| **Returns** | `0` on successful inspection; `1` otherwise. |

#### `_detect_via_partition_types`

Internal fallback heuristic based on `fdisk`/`parted` partition tables and `file` output.

| | |
|---|---|
| **Signature** | `_detect_via_partition_types <disk_path>` |
| **Purpose** | Detect OS details from partition table heuristics. |
| **Globals set** | `OS_TYPE`, `OS_DISTRO`, `OS_BOOT_MODE`, `OS_PARTITION_TABLE`, `OS_HAS_ESP` |
| **Returns** | `0` on success (may leave `OS_TYPE` as `unknown`); `1` if `fdisk`/`parted` unavailable. |

---

### `lib/windows-disk.sh`

Windows NTFS disk maintenance helpers used by `shrink-vm.sh`, `expand-vm.sh`,
and `clone-replace-disk.sh`.

#### `windows_check_ntfs`

| | |
|---|---|
| **Signature** | `windows_check_ntfs <disk_path> [log_file]` |
| **Purpose** | Check NTFS consistency on a disk image or block device using `guestfish` or `ntfsfix`. |
| **Arguments** | `$1` — Path to the disk image or block device.<br>`$2` — Log file path (default: `/var/log/windows-disk.log`). |
| **Returns** | `0` if the check passed or was skipped; `1` if issues were found. |

#### `windows_shrink_libguestfs`

| | |
|---|---|
| **Signature** | `windows_shrink_libguestfs <disk_path> <new_size_gb> [img_format] [vmid]` |
| **Purpose** | Shrink a Windows disk image to a target size using `virt-resize`. |
| **Returns** | `0` on success; `1` if `virt-resize` is unavailable or fails. |

#### `windows_shrink_ntfsresize`

| | |
|---|---|
| **Signature** | `windows_shrink_ntfsresize <disk_path> <new_size_gb> [img_format] [vmid]` |
| **Purpose** | Shrink a Windows disk image using `ntfsresize` as a fallback. |
| **Returns** | `0` on success; exits via `die()` on critical errors. |

#### `windows_expand_libguestfs`

| | |
|---|---|
| **Signature** | `windows_expand_libguestfs <disk_path> <new_size_gb> [img_format] [vmid]` |
| **Purpose** | Expand a Windows disk image to a target size using `virt-resize`. |
| **Returns** | `0` on success; `1` on failure. |

#### `windows_expand_ntfsresize`

| | |
|---|---|
| **Signature** | `windows_expand_ntfsresize <disk_path> <new_size_gb> [img_format] [vmid]` |
| **Purpose** | Expand a Windows disk image using `ntfsresize` as a fallback. |
| **Returns** | `0` on success; exits via `die()` on critical errors. |

#### `windows_clone_disk`

| | |
|---|---|
| **Signature** | `windows_clone_disk <source_disk> <target_disk> [new_size_gb] [img_format]` |
| **Purpose** | Clone a Windows disk to a new image, optionally expanding it. |
| **Returns** | `0` on success; exits via `die()` on critical errors. |

---

## Main Conversion Scripts

### `lxc-to-vm.sh`

Converts Proxmox LXC containers into bootable QEMU/KVM virtual machines.

#### Logging / Formatting Helpers

| Function | Purpose |
|----------|---------|
| `e` | Echo with backslash escape interpretation. |
| `log` | Print an info message to stdout and `$LOG_FILE`. |
| `warn` | Print a warning message to stdout and `$LOG_FILE`. |
| `err` | Print an error message to stderr and `$LOG_FILE`. |
| `ok` | Print a success message to stdout and `$LOG_FILE`. |
| `debug` | Print a debug message when `DEBUG=1`. |
| `verbose` | Alias for `debug`. |
| `checkpoint` | Print a major-phase marker to stdout and `$LOG_FILE`. |
| `die` | Log an error and exit with `E_INVALID_ARG`. |

#### Diagnostic / Setup Helpers

| Function | Purpose |
|----------|---------|
| `dump_system_info` | Dump host system information to the log when debugging. |
| `dump_container_info` | Dump source container configuration and guest OS to the log when debugging. |
| `pct_mount_retry` | Retry `pct mount` after `pct unlock` if `AUTO_FIX` is enabled. |
| `destroy_vm_if_exists` | Stop and destroy an existing VM with the target VMID when `--replace-vm` is used. |
| `error_reason_and_fix` | Map a failed command to a human-readable reason and fix suggestion. |
| `error_exit_code` | Map a failed command to a stable exit code. |
| `on_error` | Global `ERR` trap that prints diagnostics and exits with a mapped code. |
| `usage` | Display usage/help text and exit. |
| `ensure_dependency` | Verify a command exists, installing the package via `apt` if missing. |
| `cleanup` | Release all resources (mounts, loop devices, temp directories) on exit. |

#### Cluster / API Helpers

| Function | Purpose |
|----------|---------|
| `get_cluster_info` | Locate the Proxmox node that hosts a container. |
| `pve_api_call` | Perform an authenticated call to the Proxmox VE API. |
| `migrate_container_to_local` | Migrate a container from a remote cluster node to the local node. |

#### Hook / Profile / Resume Helpers

| Function | Purpose |
|----------|---------|
| `run_hook` | Execute a user-supplied hook script for a given conversion stage. |
| `analyze_growth_pattern` | Analyze historical log data to recommend a disk size. |
| `get_size_recommendation` | Display a user-friendly size recommendation for a container. |
| `ensure_profile_dir` | Ensure the profile directory exists. |
| `list_profiles` | List all saved conversion profiles. |
| `save_profile` | Save the current option set as a named profile. |
| `load_profile` | Load a named profile, applying its settings. |
| `create_snapshot` | Create an LXC snapshot before conversion. |
| `rollback_snapshot` | Roll back to the pre-conversion snapshot on failure. |
| `remove_snapshot` | Remove the pre-conversion snapshot after success. |
| `ensure_resume_dir` | Ensure the resume-state directory exists. |
| `get_resume_file` | Return the resume-state file path for a CT/VM pair. |
| `save_resume_state` | Persist partial conversion state for resume. |
| `clear_resume_state` | Remove resume state after successful conversion. |
| `check_resume_state` | Load an existing resume state if present. |

#### Batch / Wizard Helpers

| Function | Purpose |
|----------|---------|
| `process_batch_file` | Process a file containing `CTID,VMID` conversion pairs. |
| `process_range` | Expand a range specification like `100-110:200-210`. |
| `run_single_conversion` | Run one LXC→VM conversion end-to-end. |
| `show_progress` | Render a progress bar for long-running operations. |
| `spinner` | Render a spinner while a background task runs. |
| `run_wizard` | Interactive TUI wizard for guided conversion. |
| `run_preflight_validation` | Validate prerequisites before conversion. |
| `process_batch_parallel` | Run multiple conversions in parallel. |

#### Export / Template Helpers

| Function | Purpose |
|----------|---------|
| `export_vm_disk` | Export a converted VM disk to S3, NFS, SSH, or local path. |
| `convert_to_template` | Convert a VM to a Proxmox template. |
| `run_sysprep` | Clean a template (remove SSH keys, machine-id, etc.). |

#### Core Conversion Helpers

| Function | Purpose |
|----------|---------|
| `check_space` | Check whether a path has at least the requested free space. |
| `pick_work_dir` | Choose a working directory with sufficient free space. |
| `do_conversion` | Perform the full LXC→VM conversion (the main workflow). |
| `collect_vm_diagnostics` | Gather post-conversion diagnostics from the new VM. |
| `auto_fix_boot_rw_issue` | Remediate common read-only boot filesystem issues. |
| `run_check` | Run post-conversion health checks against the new VM. |

---

### `vm-to-lxc.sh`

Converts QEMU/KVM virtual machines back into Proxmox LXC containers.

#### Logging / Formatting Helpers

| Function | Purpose |
|----------|---------|
| `e` | Echo with backslash escape interpretation. |
| `log` | Print an info message to stdout and `$LOG_FILE`. |
| `warn` | Print a warning message to stdout and `$LOG_FILE`. |
| `err` | Print an error message to stderr and `$LOG_FILE`. |
| `ok` | Print a success message to stdout and `$LOG_FILE`. |
| `debug` | Print a debug message when `DEBUG=1`. |
| `verbose` | Alias for `debug`. |
| `checkpoint` | Print a major-phase marker. |
| `die` | Log an error and exit with `E_INVALID_ARG`. |

#### Diagnostic / Setup Helpers

| Function | Purpose |
|----------|---------|
| `dump_system_info` | Dump host system information to the log when debugging. |
| `dump_vm_info` | Dump source VM configuration to the log when debugging. |
| `destroy_ct_if_exists` | Stop and destroy an existing container when `--replace-ct` is used. |
| `error_reason_and_fix` | Map a failed command to a human-readable reason and fix. |
| `error_exit_code` | Map a failed command to a stable exit code. |
| `on_error` | Global `ERR` trap for actionable diagnostics. |
| `usage` | Display usage/help text and exit. |
| `ensure_dependency` | Verify a command exists, installing via `apt` if missing. |
| `cleanup` | Release all resources on exit. |

#### Cluster / API Helpers

| Function | Purpose |
|----------|---------|
| `get_cluster_info` | Locate the Proxmox node that hosts a VM. |
| `pve_api_call` | Perform an authenticated call to the Proxmox VE API. |
| `migrate_vm_to_local` | Migrate a VM from a remote cluster node to the local node. |

#### Hook / Profile / Resume Helpers

| Function | Purpose |
|----------|---------|
| `run_hook` | Execute a user-supplied hook script for a given conversion stage. |
| `get_size_recommendation` | Recommend a container disk size from VM filesystem usage. |
| `ensure_profile_dir` | Ensure the profile directory exists. |
| `list_profiles` | List all saved conversion profiles. |
| `save_profile` | Save the current option set as a named profile. |
| `load_profile` | Load a named profile. |
| `create_snapshot` | Create a VM snapshot before conversion. |
| `rollback_snapshot` | Roll back to the pre-conversion snapshot on failure. |
| `remove_snapshot` | Remove the pre-conversion snapshot after success. |
| `ensure_resume_dir` | Ensure the resume-state directory exists. |
| `get_resume_file` | Return the resume-state file path for a VM/CT pair. |
| `save_resume_state` | Persist partial conversion state for resume. |
| `clear_resume_state` | Remove resume state after success. |
| `check_resume_state` | Load an existing resume state if present. |

#### Batch / Wizard Helpers

| Function | Purpose |
|----------|---------|
| `process_batch_file` | Process a file containing `VMID,CTID` conversion pairs. |
| `process_range` | Expand a range specification like `100-110:200-210`. |
| `run_single_conversion` | Run one VM→LXC conversion end-to-end. |
| `show_progress` | Render a progress bar. |
| `run_wizard` | Interactive TUI wizard. |
| `run_preflight_validation` | Validate prerequisites before conversion. |
| `process_batch_parallel` | Run multiple conversions in parallel. |

#### Core Conversion Helpers

| Function | Purpose |
|----------|---------|
| `check_space` | Return available space (MB) on a path. |
| `pick_work_dir` | Choose a working directory with sufficient free space. |
| `do_conversion` | Perform the full VM→LXC conversion (the main workflow). |

---

## Disk Utility Scripts

### `shrink-lxc.sh`

Shrinks an LXC container root disk to actual usage plus configurable headroom.

| Function | Purpose |
|----------|---------|
| `debug` | Print debug messages when `DEBUG=1`. |
| `verbose` | Print verbose messages to log, optionally to console. |
| `e` | Echo with escape interpretation. |
| `log` | Info log to stdout and log file. |
| `warn` | Warning log. |
| `err` | Error log to stderr and log file. |
| `ok` | Success log. |
| `die` | Fatal error exit. |
| `error_reason_and_fix` | Map a failed command to a reason and fix. |
| `error_exit_code` | Map a failed command to a stable exit code. |
| `on_error` | Global `ERR` trap. |
| `usage` | Display help and exit. |

The remainder of the script is procedural: argument parsing, input validation,
container stop/mount, filesystem shrink, storage resize, and restart.

---

### `expand-lxc.sh`

Expands an LXC container root disk using absolute, additive, percentage, or
maximum-available modes.

| Function | Purpose |
|----------|---------|
| `debug` | Print debug messages when `DEBUG=1`. |
| `verbose` | Print verbose messages. |
| `e` | Echo with escape interpretation. |
| `log` / `warn` / `err` / `ok` | Logging helpers. |
| `die` | Fatal error exit. |
| `error_reason_and_fix` | Map a failed command to a reason and fix. |
| `error_exit_code` | Map a failed command to a stable exit code. |
| `on_error` | Global `ERR` trap. |
| `usage` | Display help and exit. |
| `get_pool_free_space` | Return free space (GB) in the container's storage pool. |
| `get_pool_total_size` | Return total size (GB) of the container's storage pool. |
| `calculate_target_size` | Compute the target disk size from the selected expansion mode. |

---

### `shrink-vm.sh`

Shrinks a VM disk to actual filesystem usage plus headroom.

| Function | Purpose |
|----------|---------|
| `debug` | Print debug messages when `DEBUG=1`. |
| `verbose` | Print verbose messages. |
| `e` | Echo with escape interpretation. |
| `log` / `warn` / `err` / `ok` | Logging helpers. |
| `die` | Fatal error exit. |
| `error_reason_and_fix` | Map a failed command to a reason and fix. |
| `error_exit_code` | Map a failed command to a stable exit code. |
| `on_error` | Global `ERR` trap. |
| `usage` | Display help and exit. |

Additional procedural logic handles VM stop, disk mapping, filesystem shrink,
image truncation, and VM recreation.

---

### `expand-vm.sh`

Expands a VM disk to an absolute or additive target size.

| Function | Purpose |
|----------|---------|
| `debug` | Print debug messages when `DEBUG=1`. |
| `verbose` | Print verbose messages. |
| `e` | Echo with escape interpretation. |
| `log` / `warn` / `err` / `ok` | Logging helpers. |
| `die` | Fatal error exit. |
| `error_reason_and_fix` | Map a failed command to a reason and fix. |
| `error_exit_code` | Map a failed command to a stable exit code. |
| `on_error` | Global `ERR` trap. |
| `usage` | Display help and exit. |
| `get_pool_free_space` | Return free space (GB) in the VM's storage pool. |
| `get_pool_total_size` | Return total size (GB) of the VM's storage pool. |
| `calculate_target_size` | Compute the target disk size from the selected expansion mode. |

---

### `clone-replace-disk.sh`

Clones a VM or LXC disk and optionally replaces it in the original guest.

| Function | Purpose |
|----------|---------|
| `debug` | Print debug messages when `DEBUG=1`. |
| `verbose` | Print verbose messages. |
| `e` | Echo with escape interpretation. |
| `log` / `warn` / `err` / `ok` | Logging helpers. |
| `die` | Fatal error exit. |
| `error_reason_and_fix` | Map a failed command to a reason and fix. |
| `error_exit_code` | Map a failed command to a stable exit code. |
| `on_error` | Global `ERR` trap. |
| `usage` | Display help and exit. |

The main body parses options, validates source/target disks, performs the clone,
and optionally updates the guest configuration.

---

## Utility Scripts

### `test-remote-pve.sh`

Validates the toolkit against a remote Proxmox VE host over SSH.

| Function | Purpose |
|----------|---------|
| `ssh_cmd` | Run a command on the remote PVE host via `sshpass`/SSH. |
| `scp_cmd` | Copy a file to/from the remote PVE host via `sshpass`/SCP. |

The script then runs a sequence of upload, dependency, and conversion smoke
tests against the remote node.

---

### `add-file-headers.sh`

Maintains the standardized file-header comments across the repository.

| Function | Purpose |
|----------|---------|
| `usage` | Display help and exit. |
| `die` | Print a fatal error and exit with a custom code. |
| `log_msg` | Append a timestamped message to the script log. |
| `array_contains` | Check whether a value exists in an array. |
| `is_binary` | Determine whether a file is binary. |
| `get_comment_style` | Choose the correct comment style for a file extension. |
| `generate_description` | Generate a description string for a file from its header or name. |
| `generate_header` | Render the standard header block for a file. |
| `process_file` | Add or update the header in a single file (dry-run/check aware). |
| `main` | Iterate over repository files and apply headers. |

---

## Exit Codes

Most scripts use the following stable exit codes for programmatic error handling:

| Code | Name | Meaning |
|------|------|---------|
| `0` | `SUCCESS` | Operation completed successfully. |
| `1` | `E_INVALID_ARG` | Invalid arguments or generic failure. |
| `2` | `E_NOT_FOUND` | Container, VM, or resource not found. |
| `3` | `E_DISK_FULL` | Insufficient disk space. |
| `4` | `E_PERMISSION` | Permission denied. |
| `5` | `E_MIGRATION` / `E_SHRINK_FAILED` / `E_EXPAND_FAILED` / `E_NO_SPACE` | Operation-specific failure (varies by script; see script source). |
| `6` | `E_CONVERSION` | Core conversion process failed. |

Refer to each script's `E_*` constants for exact semantics.
