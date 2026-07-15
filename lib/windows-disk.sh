#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# ### lxc-to-vm file header ###
# File: windows-disk.sh
# Description: Windows disk
# License: MIT
# ==============================================================================

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
readonly WINDOWS_MIN_DISK_GB=30

# ------------------------------------------------------------------------------
# Logging fallback
# ------------------------------------------------------------------------------
# These functions are normally defined by the sourcing script. Provide minimal
# defaults so the library can be sourced standalone without failing.
: "${LOG_FILE:=/var/log/windows-disk.log}"
if [[ "$(type -t log 2>/dev/null)" != "function" ]]; then
    log() { printf "[*] %s\n" "$*" | tee -a "$LOG_FILE"; }
fi
if [[ "$(type -t warn 2>/dev/null)" != "function" ]]; then
    warn() { printf "[!] %s\n" "$*" | tee -a "$LOG_FILE"; }
fi
if [[ "$(type -t ok 2>/dev/null)" != "function" ]]; then
    ok() { printf "[OK] %s\n" "$*" | tee -a "$LOG_FILE"; }
fi
if [[ "$(type -t die 2>/dev/null)" != "function" ]]; then
    die() { printf "[FATAL] %s\n" "$*" >&2; exit "${E_INVALID_ARG:-1}"; }
fi

### Function: windows_check_ntfs
# Check NTFS consistency on a disk image or block device.
#
# Arguments:
#   $1 - Path to the disk image or block device.
#   $2 - Log file path (default: /var/log/windows-disk.log).
#
# Outputs:
#   Messages to stdout/log via log/warn functions.
#
# Returns:
#   0 if the NTFS check passed or was skipped, 1 if issues were found.
windows_check_ntfs() {
    local disk_path="$1"
    local log_file="${2:-/var/log/windows-disk.log}"
    local LOG_FILE="$log_file"

    log "Checking NTFS consistency on $disk_path..."

    if command -v guestfish &>/dev/null; then
        # Use guestfs fsck (safer, no loop mount)
        if ! LIBGUESTFS_BACKEND=direct guestfish \
            --ro \
            -a "$disk_path" \
            -i fsck "ntfs" 2>>"$log_file"; then
            warn "guestfs NTFS check found issues. Consider running chkdsk inside Windows."
            return 1
        fi
    elif command -v ntfsfix &>/dev/null; then
        # Fallback: ntfsfix (less safe, requires mount or loop device)
        if [[ -b "$disk_path" ]]; then
            ntfsfix -n "$disk_path" >> "$log_file" 2>&1 || {
                warn "ntfsfix found issues on $disk_path"
                return 1
            }
        else
            # Image file: need loop device
            local loop_dev
            loop_dev=$(losetup --show -f "$disk_path")

            __cleanup_check_ntfs_loop() {
                if [[ -n "${loop_dev:-}" ]]; then
                    losetup -d "$loop_dev" 2>/dev/null || true
                fi
            }
            trap '__cleanup_check_ntfs_loop' RETURN

            ntfsfix -n "$loop_dev" >> "$log_file" 2>&1 || {
                warn "ntfsfix found issues on loop device"
                __cleanup_check_ntfs_loop
                trap - RETURN
                return 1
            }

            __cleanup_check_ntfs_loop
            trap - RETURN
        fi
    else
        warn "No NTFS checking tool available (guestfish or ntfsfix). Skipping check."
        return 0
    fi

    log "NTFS consistency check passed."
    return 0
}

### Function: windows_shrink_libguestfs
# Shrink a Windows disk image to a target size using virt-resize (libguestfs).
#
# Arguments:
#   $1 - Path to the source disk image.
#   $2 - Target size in GiB.
#   $3 - Disk image format (default: "raw").
#   $4 - Optional VMID used to name temporary files.
#
# Outputs:
#   Progress messages and virt-resize output.
#
# Returns:
#   0 on success, 1 if virt-resize is unavailable or the operation fails.
windows_shrink_libguestfs() {
    local disk_path="$1"
    local new_size_gb="$2"
    local img_format="${3:-raw}"
    local vmid="${4:-}"

    log "Using libguestfs for Windows shrink..."

    if ! command -v virt-resize &>/dev/null; then
        warn "virt-resize not available. Falling back to ntfsresize."
        return 1
    fi

    local temp_raw=""
    local temp_new
    if [[ -n "$vmid" ]]; then
        temp_new=$(mktemp "/tmp/vm-${vmid}-shrink-new.XXXXXX.raw")
    else
        temp_new=$(mktemp "/tmp/vm-shrink-new.XXXXXX.raw")
    fi

    __cleanup_shrink_libguestfs() {
        if [[ -n "${temp_new:-}" && "$temp_new" != "$disk_path" ]]; then
            rm -f "$temp_new" 2>/dev/null || true
        fi
        if [[ -n "${temp_raw:-}" && "$temp_raw" != "$disk_path" ]]; then
            rm -f "$temp_raw" 2>/dev/null || true
        fi
    }
    trap '__cleanup_shrink_libguestfs' RETURN

    # Convert to raw if needed
    if [[ "$img_format" != "raw" ]]; then
        if [[ -n "$vmid" ]]; then
            temp_raw=$(mktemp "/tmp/vm-${vmid}-shrink-raw.XXXXXX.raw")
        else
            temp_raw=$(mktemp "/tmp/vm-shrink-raw.XXXXXX.raw")
        fi
        log "Converting $img_format to temporary raw image..."
        qemu-img convert -f "$img_format" -O raw "$disk_path" "$temp_raw" || {
            __cleanup_shrink_libguestfs
            trap - RETURN
            die "qemu-img convert failed."
        }
    else
        temp_raw="$disk_path"
    fi

    # Shrink using virt-resize (auto-discovers partitions)
    log "Shrinking with virt-resize..."
    if ! LIBGUESTFS_BACKEND=direct virt-resize \
        --shrink /dev/sda1 \
        --output "$temp_new" \
        "$temp_raw" 2>&1 | tee -a "$LOG_FILE"; then
        __cleanup_shrink_libguestfs
        trap - RETURN
        return 1
    fi

    # Convert back if needed
    if [[ "$img_format" != "raw" ]]; then
        log "Converting back to $img_format..."
        qemu-img convert -f raw -O "$img_format" "$temp_new" "$disk_path" || {
            __cleanup_shrink_libguestfs
            trap - RETURN
            die "qemu-img convert failed."
        }
    else
        mv -f "$temp_new" "$disk_path" || {
            __cleanup_shrink_libguestfs
            trap - RETURN
            die "mv failed."
        }
    fi

    __cleanup_shrink_libguestfs
    trap - RETURN

    ok "Windows shrink complete via libguestfs."
    return 0
}

### Function: windows_shrink_ntfsresize
# Shrink a Windows disk image using ntfsresize as a fallback.
#
# Arguments:
#   $1 - Path to the source disk image.
#   $2 - Target size in GiB.
#   $3 - Disk image format (default: "raw").
#   $4 - Optional VMID used to name temporary files.
#
# Outputs:
#   Progress messages and ntfsresize output.
#
# Returns:
#   0 on success, exits via die() on critical errors.
windows_shrink_ntfsresize() {
    local disk_path="$1"
    local new_size_gb="$2"
    local img_format="${3:-raw}"
    local vmid="${4:-}"

    log "Using ntfsresize fallback for Windows shrink..."

    if ! command -v ntfsresize &>/dev/null; then
        die "ntfsresize not available. Install ntfs-3g: apt install ntfs-3g"
    fi

    local temp_raw=""
    local loop_dev=""

    __cleanup_shrink_ntfsresize() {
        if [[ -n "${loop_dev:-}" ]]; then
            losetup -d "$loop_dev" 2>/dev/null || true
        fi
        if [[ -n "${temp_raw:-}" && "$temp_raw" != "$disk_path" ]]; then
            rm -f "$temp_raw" 2>/dev/null || true
        fi
    }

    if [[ "$img_format" == "qcow2" ]]; then
        if [[ -n "$vmid" ]]; then
            temp_raw=$(mktemp "/tmp/vm-${vmid}-shrink.XXXXXX.raw")
        else
            temp_raw=$(mktemp "/tmp/vm-shrink.XXXXXX.raw")
        fi
        trap '__cleanup_shrink_ntfsresize' RETURN
        qemu-img convert -f qcow2 -O raw "$disk_path" "$temp_raw" || {
            __cleanup_shrink_ntfsresize
            trap - RETURN
            die "qemu-img convert failed."
        }
        loop_dev=$(losetup --show -f "$temp_raw") || {
            __cleanup_shrink_ntfsresize
            trap - RETURN
            die "losetup failed for $temp_raw."
        }
    else
        loop_dev=$(losetup --show -f "$disk_path") || {
            __cleanup_shrink_ntfsresize
            trap - RETURN
            die "losetup failed for $disk_path."
        }
    fi

    trap '__cleanup_shrink_ntfsresize' RETURN

    # Check NTFS before shrink
    ntfsresize -i "$loop_dev" >> "$LOG_FILE" 2>&1 || {
        __cleanup_shrink_ntfsresize
        trap - RETURN
        die "ntfsresize info failed."
    }

    # Shrink NTFS
    local new_size_bytes=$((new_size_gb * 1024 * 1024 * 1024))
    log "Shrinking NTFS to ${new_size_gb}GB..."
    ntfsresize --size "${new_size_bytes}" "$loop_dev" >> "$LOG_FILE" 2>&1 || {
        __cleanup_shrink_ntfsresize
        trap - RETURN
        die "ntfsresize shrink failed."
    }

    losetup -d "$loop_dev" 2>/dev/null || {
        __cleanup_shrink_ntfsresize
        trap - RETURN
        die "Failed to detach loop device $loop_dev."
    }

    if [[ "$img_format" == "qcow2" ]]; then
        # Truncate raw and convert back
        truncate -s "${new_size_gb}G" "$temp_raw" || {
            __cleanup_shrink_ntfsresize
            trap - RETURN
            die "truncate failed."
        }
        qemu-img convert -f raw -O qcow2 "$temp_raw" "$disk_path" || {
            __cleanup_shrink_ntfsresize
            trap - RETURN
            die "qemu-img convert failed."
        }
        rm -f "$temp_raw"
    else
        # Raw image: truncate
        truncate -s "${new_size_gb}G" "$disk_path" || {
            __cleanup_shrink_ntfsresize
            trap - RETURN
            die "truncate failed."
        }
    fi

    __cleanup_shrink_ntfsresize
    trap - RETURN
    ok "Windows shrink complete via ntfsresize."
    return 0
}

### Function: windows_expand_libguestfs
# Expand a Windows disk image to a target size using virt-resize (libguestfs).
#
# Arguments:
#   $1 - Path to the source disk image.
#   $2 - Target size in GiB.
#   $3 - Disk image format (default: "raw").
#   $4 - Optional VMID used to name temporary files.
#
# Outputs:
#   Progress messages and virt-resize output.
#
# Returns:
#   0 on success, 1 if virt-resize is unavailable or the operation fails.
windows_expand_libguestfs() {
    local disk_path="$1"
    local new_size_gb="$2"
    local img_format="${3:-raw}"
    local vmid="${4:-}"

    log "Using libguestfs for Windows expand..."

    if ! command -v virt-resize &>/dev/null; then
        warn "virt-resize not available. Falling back to ntfsresize."
        return 1
    fi

    local temp_raw=""
    local temp_new
    if [[ -n "$vmid" ]]; then
        temp_new=$(mktemp "/tmp/vm-${vmid}-expand-new.XXXXXX.raw")
    else
        temp_new=$(mktemp "/tmp/vm-expand-new.XXXXXX.raw")
    fi

    __cleanup_expand_libguestfs() {
        if [[ -n "${temp_new:-}" && "$temp_new" != "$disk_path" ]]; then
            rm -f "$temp_new" 2>/dev/null || true
        fi
        if [[ -n "${temp_raw:-}" && "$temp_raw" != "$disk_path" ]]; then
            rm -f "$temp_raw" 2>/dev/null || true
        fi
    }
    trap '__cleanup_expand_libguestfs' RETURN

    if [[ "$img_format" != "raw" ]]; then
        if [[ -n "$vmid" ]]; then
            temp_raw=$(mktemp "/tmp/vm-${vmid}-expand-raw.XXXXXX.raw")
        else
            temp_raw=$(mktemp "/tmp/vm-expand-raw.XXXXXX.raw")
        fi
        log "Converting $img_format to temporary raw image..."
        qemu-img convert -f "$img_format" -O raw "$disk_path" "$temp_raw" || {
            __cleanup_expand_libguestfs
            trap - RETURN
            die "qemu-img convert failed."
        }
    else
        temp_raw="$disk_path"
    fi

    # Expand virtual disk first (virt-resize needs space)
    truncate -s "${new_size_gb}G" "$temp_raw" || {
        __cleanup_expand_libguestfs
        trap - RETURN
        die "truncate failed."
    }

    log "Expanding with virt-resize..."
    if ! LIBGUESTFS_BACKEND=direct virt-resize \
        --expand /dev/sda1 \
        --output "$temp_new" \
        "$temp_raw" 2>&1 | tee -a "$LOG_FILE"; then
        __cleanup_expand_libguestfs
        trap - RETURN
        return 1
    fi

    if [[ "$img_format" != "raw" ]]; then
        log "Converting back to $img_format..."
        qemu-img convert -f raw -O "$img_format" "$temp_new" "$disk_path" || {
            __cleanup_expand_libguestfs
            trap - RETURN
            die "qemu-img convert failed."
        }
    else
        mv -f "$temp_new" "$disk_path" || {
            __cleanup_expand_libguestfs
            trap - RETURN
            die "mv failed."
        }
    fi

    __cleanup_expand_libguestfs
    trap - RETURN

    ok "Windows expand complete via libguestfs."
    return 0
}

### Function: windows_expand_ntfsresize
# Expand a Windows disk image using ntfsresize as a fallback.
#
# Arguments:
#   $1 - Path to the source disk image.
#   $2 - Target size in GiB.
#   $3 - Disk image format (default: "raw").
#   $4 - Optional VMID used to name temporary files.
#
# Outputs:
#   Progress messages and ntfsresize output.
#
# Returns:
#   0 on success, exits via die() on critical errors.
windows_expand_ntfsresize() {
    local disk_path="$1"
    local new_size_gb="$2"
    local img_format="${3:-raw}"
    local vmid="${4:-}"

    log "Using ntfsresize fallback for Windows expand..."

    if ! command -v ntfsresize &>/dev/null; then
        die "ntfsresize not available. Install ntfs-3g: apt install ntfs-3g"
    fi

    local temp_raw=""
    local loop_dev=""

    __cleanup_expand_ntfsresize() {
        if [[ -n "${loop_dev:-}" ]]; then
            losetup -d "$loop_dev" 2>/dev/null || true
        fi
        if [[ -n "${temp_raw:-}" && "$temp_raw" != "$disk_path" ]]; then
            rm -f "$temp_raw" 2>/dev/null || true
        fi
    }

    if [[ "$img_format" == "qcow2" ]]; then
        if [[ -n "$vmid" ]]; then
            temp_raw=$(mktemp "/tmp/vm-${vmid}-expand.XXXXXX.raw")
        else
            temp_raw=$(mktemp "/tmp/vm-expand.XXXXXX.raw")
        fi
        trap '__cleanup_expand_ntfsresize' RETURN
        qemu-img convert -f qcow2 -O raw "$disk_path" "$temp_raw" || {
            __cleanup_expand_ntfsresize
            trap - RETURN
            die "qemu-img convert failed."
        }

        # Expand raw image
        truncate -s "${new_size_gb}G" "$temp_raw" || {
            __cleanup_expand_ntfsresize
            trap - RETURN
            die "truncate failed."
        }
        loop_dev=$(losetup --show -f "$temp_raw") || {
            __cleanup_expand_ntfsresize
            trap - RETURN
            die "losetup failed for $temp_raw."
        }
    else
        # Raw image: expand file then loop mount
        truncate -s "${new_size_gb}G" "$disk_path" || {
            __cleanup_expand_ntfsresize
            trap - RETURN
            die "truncate failed."
        }
        loop_dev=$(losetup --show -f "$disk_path") || {
            __cleanup_expand_ntfsresize
            trap - RETURN
            die "losetup failed for $disk_path."
        }
    fi

    trap '__cleanup_expand_ntfsresize' RETURN

    # Expand NTFS to fill
    log "Expanding NTFS filesystem..."
    ntfsresize --force --force "$loop_dev" >> "$LOG_FILE" 2>&1 || {
        __cleanup_expand_ntfsresize
        trap - RETURN
        die "ntfsresize expand failed."
    }

    losetup -d "$loop_dev" 2>/dev/null || {
        __cleanup_expand_ntfsresize
        trap - RETURN
        die "Failed to detach loop device $loop_dev."
    }

    if [[ "$img_format" == "qcow2" ]]; then
        qemu-img convert -f raw -O qcow2 "$temp_raw" "$disk_path" || {
            __cleanup_expand_ntfsresize
            trap - RETURN
            die "qemu-img convert failed."
        }
    fi

    __cleanup_expand_ntfsresize
    trap - RETURN
    ok "Windows expand complete via ntfsresize."
    return 0
}

### Function: windows_clone_disk
# Clone a Windows disk to a new image, optionally expanding it.
#
# Arguments:
#   $1 - Path to the source disk image.
#   $2 - Path to the target disk image.
#   $3 - Optional target size in GiB (empty means keep size).
#   $4 - Disk image format (default: "raw").
#
# Outputs:
#   Progress messages and virt-resize/qemu-img output.
#
# Returns:
#   0 on success, exits via die() on critical errors.
windows_clone_disk() {
    local source_disk="$1"
    local target_disk="$2"
    local new_size_gb="${3:-}"
    local img_format="${4:-raw}"

    log "Cloning Windows disk..."

    if command -v virt-resize &>/dev/null; then
        # libguestfs handles boot config preservation
        local extra_args=()
        [[ -n "$new_size_gb" ]] && extra_args+=("--expand" "/dev/sda1")

        if ! LIBGUESTFS_BACKEND=direct virt-resize \
            "${extra_args[@]}" \
            --output "$target_disk" \
            "$source_disk" 2>&1 | tee -a "$LOG_FILE"; then
            die "virt-resize clone failed."
        fi
    else
        # Fallback: qemu-img convert (preserves boot sector but not BCD adjustments)
        log "Using qemu-img convert fallback..."
        qemu-img convert -f "$img_format" -O "$img_format" "$source_disk" "$target_disk"

        if [[ -n "$new_size_gb" ]]; then
            # Need to expand NTFS afterwards
            windows_expand_ntfsresize "$target_disk" "$new_size_gb" "$img_format"
        fi
    fi

    ok "Windows disk clone complete."
    return 0
}
