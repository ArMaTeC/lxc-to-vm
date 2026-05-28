#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# ### lxc-to-vm file header ###
# File: windows-disk.sh
# Description: Windows disk
# License: MIT
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
readonly WINDOWS_MIN_DISK_GB=30

# ------------------------------------------------------------------------------
# NTFS Consistency Check
# ------------------------------------------------------------------------------
windows_check_ntfs() {
    local disk_path="$1"
    local log_file="${2:-/var/log/windows-disk.log}"

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
            # shellcheck disable=SC2064
            trap "losetup -d '$loop_dev' 2>/dev/null || true" RETURN
            ntfsfix -n "$loop_dev" >> "$log_file" 2>&1 || {
                warn "ntfsfix found issues on loop device"
                return 1
            }
            losetup -d "$loop_dev" 2>/dev/null || true
            trap - RETURN
        fi
    else
        warn "No NTFS checking tool available (guestfish or ntfsfix). Skipping check."
        return 1
    fi

    log "NTFS consistency check passed."
    return 0
}

# ------------------------------------------------------------------------------
# Shrink: libguestfs path
# ------------------------------------------------------------------------------
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

    local temp_raw="/tmp/vm-${vmid}-shrink.raw"
    local temp_new="/tmp/vm-${vmid}-new.raw"
    # shellcheck disable=SC2064
    trap "rm -f '$temp_raw' '$temp_new' 2>/dev/null || true" RETURN

    # Convert to raw if needed
    if [[ "$img_format" != "raw" ]]; then
        log "Converting $img_format to temporary raw image..."
        qemu-img convert -f "$img_format" -O raw "$disk_path" "$temp_raw"
    else
        temp_raw="$disk_path"
    fi

    # Shrink using virt-resize (auto-discovers partitions)
    log "Shrinking with virt-resize..."
    if ! LIBGUESTFS_BACKEND=direct virt-resize \
        --shrink /dev/sda1 \
        --output "$temp_new" \
        "$temp_raw" 2>&1 | tee -a "$LOG_FILE"; then
        rm -f "$temp_new"
        return 1
    fi

    # Convert back if needed
    if [[ "$img_format" != "raw" ]]; then
        log "Converting back to $img_format..."
        qemu-img convert -f raw -O "$img_format" "$temp_new" "$disk_path"
    else
        mv -f "$temp_new" "$disk_path"
    fi

    rm -f "$temp_raw" "$temp_new"
    trap - RETURN

    ok "Windows shrink complete via libguestfs."
    return 0
}

# ------------------------------------------------------------------------------
# Shrink: ntfsresize fallback path
# ------------------------------------------------------------------------------
windows_shrink_ntfsresize() {
    local disk_path="$1"
    local new_size_gb="$2"
    local img_format="${3:-raw}"
    local vmid="${4:-}"

    log "Using ntfsresize fallback for Windows shrink..."

    if ! command -v ntfsresize &>/dev/null; then
        die "ntfsresize not available. Install ntfs-3g: apt install ntfs-3g"
    fi

    local temp_raw="/tmp/vm-${vmid}-shrink.raw"
    local loop_dev=""

    if [[ "$img_format" == "qcow2" ]]; then
        # shellcheck disable=SC2064
        trap "rm -f '$temp_raw' 2>/dev/null || true" RETURN
        qemu-img convert -f qcow2 -O raw "$disk_path" "$temp_raw"
        loop_dev=$(losetup --show -f "$temp_raw")
    else
        loop_dev=$(losetup --show -f "$disk_path")
    fi

    # shellcheck disable=SC2064
    trap "losetup -d '$loop_dev' 2>/dev/null || true; rm -f '$temp_raw' 2>/dev/null || true" RETURN

    # Check NTFS before shrink
    ntfsresize -i "$loop_dev" >> "$LOG_FILE" 2>&1 || die "ntfsresize info failed."

    # Shrink NTFS
    local new_size_bytes=$((new_size_gb * 1024 * 1024 * 1024))
    log "Shrinking NTFS to ${new_size_gb}GB..."
    ntfsresize --size "${new_size_bytes}" "$loop_dev" >> "$LOG_FILE" 2>&1 || die "ntfsresize shrink failed."

    losetup -d "$loop_dev"

    if [[ "$img_format" == "qcow2" ]]; then
        # Truncate raw and convert back
        truncate -s "${new_size_gb}G" "$temp_raw"
        qemu-img convert -f raw -O qcow2 "$temp_raw" "$disk_path"
        rm -f "$temp_raw"
    else
        # Raw image: truncate
        truncate -s "${new_size_gb}G" "$disk_path"
    fi

    trap - RETURN
    ok "Windows shrink complete via ntfsresize."
    return 0
}

# ------------------------------------------------------------------------------
# Expand: libguestfs path
# ------------------------------------------------------------------------------
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

    local temp_raw="/tmp/vm-${vmid}-expand.raw"
    local temp_new="/tmp/vm-${vmid}-new.raw"
    # shellcheck disable=SC2064
    trap "rm -f '$temp_raw' '$temp_new' 2>/dev/null || true" RETURN

    if [[ "$img_format" != "raw" ]]; then
        log "Converting $img_format to temporary raw image..."
        qemu-img convert -f "$img_format" -O raw "$disk_path" "$temp_raw"
    else
        temp_raw="$disk_path"
    fi

    # Expand virtual disk first (virt-resize needs space)
    truncate -s "${new_size_gb}G" "$temp_raw"

    log "Expanding with virt-resize..."
    if ! LIBGUESTFS_BACKEND=direct virt-resize \
        --expand /dev/sda1 \
        --output "$temp_new" \
        "$temp_raw" 2>&1 | tee -a "$LOG_FILE"; then
        rm -f "$temp_new"
        return 1
    fi

    if [[ "$img_format" != "raw" ]]; then
        log "Converting back to $img_format..."
        qemu-img convert -f raw -O "$img_format" "$temp_new" "$disk_path"
    else
        mv -f "$temp_new" "$disk_path"
    fi

    rm -f "$temp_raw" "$temp_new"
    trap - RETURN

    ok "Windows expand complete via libguestfs."
    return 0
}

# ------------------------------------------------------------------------------
# Expand: ntfsresize fallback path
# ------------------------------------------------------------------------------
windows_expand_ntfsresize() {
    local disk_path="$1"
    local new_size_gb="$2"
    local img_format="${3:-raw}"
    local vmid="${4:-}"

    log "Using ntfsresize fallback for Windows expand..."

    if ! command -v ntfsresize &>/dev/null; then
        die "ntfsresize not available. Install ntfs-3g: apt install ntfs-3g"
    fi

    local loop_dev=""

    if [[ "$img_format" == "qcow2" ]]; then
        local temp_raw="/tmp/vm-${vmid}-expand.raw"
        # shellcheck disable=SC2064
        trap "rm -f '$temp_raw' 2>/dev/null || true" RETURN
        qemu-img convert -f qcow2 -O raw "$disk_path" "$temp_raw"

        # Expand raw image
        truncate -s "${new_size_gb}G" "$temp_raw"
        loop_dev=$(losetup --show -f "$temp_raw")
    else
        # Raw image: expand file then loop mount
        truncate -s "${new_size_gb}G" "$disk_path"
        loop_dev=$(losetup --show -f "$disk_path")
    fi

    # shellcheck disable=SC2064
    trap "losetup -d '$loop_dev' 2>/dev/null || true; rm -f '/tmp/vm-${vmid}-expand.raw' 2>/dev/null || true" RETURN

    # Expand NTFS to fill
    log "Expanding NTFS filesystem..."
    ntfsresize --force --force "$loop_dev" >> "$LOG_FILE" 2>&1 || die "ntfsresize expand failed."

    losetup -d "$loop_dev"

    if [[ "$img_format" == "qcow2" ]]; then
        qemu-img convert -f raw -O qcow2 "/tmp/vm-${vmid}-expand.raw" "$disk_path"
        rm -f "/tmp/vm-${vmid}-expand.raw"
    fi

    trap - RETURN
    ok "Windows expand complete via ntfsresize."
    return 0
}

# ------------------------------------------------------------------------------
# Clone Disk for Windows VMs
# ------------------------------------------------------------------------------
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
