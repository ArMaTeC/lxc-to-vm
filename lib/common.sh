#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# ### lxc-to-vm file header ###
# File: common.sh
# Description: Common
# License: MIT
# ==============================================================================

# Resolve the directory where this library lives
readonly _LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

### Function: lib_source
# Source a sibling library from the same directory by filename.
#
# Arguments:
#   $1 - Name of the library file to source (e.g., "os-detect.sh").
#
# Outputs:
#   Error message to stderr if the library is missing.
#
# Returns:
#   0 on success, exits 1 if the library file is not found.
lib_source() {
    local lib_name="$1"
    local lib_path="${_LIB_DIR}/${lib_name}"
    if [[ -f "$lib_path" ]]; then
        # shellcheck source=/dev/null
        source "$lib_path"
    else
        echo "[ERROR] Missing library: ${lib_path}" >&2
        exit 1
    fi
}

### Function: check_target_collision
# Check whether a target VM/CT ID already exists and ask before overwriting.
#
# Arguments:
#   $1 - Target type: "vm" or "ct"
#   $2 - Target ID
#   $3 - Replace flag (non-empty truthy): skip prompt and allow replacement
#
# Globals:
#   SKIP_CHECKS - if set to "true", this check is bypassed
#
# Returns:
#   Exits via die() if the user declines; otherwise returns 1 if the target
#   does not exist or 0 if it exists and is allowed to be overwritten.
check_target_collision() {
    local target_type="$1" target_id="$2" replace_flag="${3:-}"

    [[ "${SKIP_CHECKS:-false}" == "true" ]] && return 0
    [[ -z "$target_id" ]] && return 1

    local config_cmd=""
    if [[ "$target_type" == "vm" ]]; then
        config_cmd="qm config"
    elif [[ "$target_type" == "ct" ]]; then
        config_cmd="pct config"
    else
        return 1
    fi

    if ! $config_cmd "$target_id" >/dev/null 2>&1; then
        return 1
    fi

    if [[ -n "$replace_flag" && "$replace_flag" != "false" ]]; then
        warn "${target_type^^} ID $target_id already exists; will overwrite (--replace-* set)"
        return 0
    fi

    echo ""
    warn "${target_type^^} ID $target_id already exists. Continuing will DESTROY it and its data."
    read -rp "Continue and overwrite? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        die "Aborted to avoid overwriting existing ${target_type^^} $target_id"
    fi
    return 0
}

### Function: check_target_space
# Verify that a Proxmox storage has enough free space for an operation.
#
# Arguments:
#   $1 - Storage name (e.g. local-lvm)
#   $2 - Required free space in GB
#   $3 - Optional label for log messages
#
# Globals:
#   SKIP_CHECKS - if set to "true", this check is bypassed
#
# Returns:
#   0 if enough space is available; exits via die() otherwise.
check_target_space() {
    local storage="$1" required_gb="$2" label="${3:-target}"
    local free_gb=0

    [[ "${SKIP_CHECKS:-false}" == "true" ]] && return 0
    [[ -z "$storage" ]] && die "Storage name required for space check"
    [[ "$required_gb" =~ ^[0-9]+$ ]] || die "Required space must be an integer (GB)"

    local storage_type
    storage_type=$(pvesm status 2>/dev/null | awk -v s="$storage" 'NR>1 && $1==s{print $2; exit}')
    [[ -n "$storage_type" ]] || die "Storage '$storage' not found"

    case "$storage_type" in
        lvmthin|lvm)
            local vg_name
            # Try to derive the VG from an existing volume on this storage
            vg_name=$(pvesm list "$storage" --output-format json 2>/dev/null \
                | grep -oP '"volid":"\K[^"]+' | head -1 \
                | xargs -I{} pvesm path "{}" 2>/dev/null | cut -d'/' -f3)
            [[ -z "$vg_name" ]] && vg_name=$(vgs --noheadings -o vg_name 2>/dev/null | head -1 | tr -d ' ')
            [[ -n "$vg_name" ]] || die "Could not determine volume group for '$storage'"
            local free_mb
            free_mb=$(vgs --noheadings --units m -o vg_free "$vg_name" 2>/dev/null | awk '{print $1}' | sed 's/m//i' | cut -d'.' -f1)
            free_gb=$((free_mb / 1024))
            ;;
        zfspool)
            local zfs_dataset
            zfs_dataset=$(pvesm list "$storage" --output-format json 2>/dev/null \
                | grep -oP '"volid":"\K[^"]+' | head -1 \
                | xargs -I{} pvesm path "{}" 2>/dev/null | sed 's|/dev/zd0||')
            [[ -n "$zfs_dataset" ]] || die "Could not determine ZFS dataset for '$storage'"
            local avail_gb
            avail_gb=$(zfs list -H -o available "$zfs_dataset" 2>/dev/null | awk '{print $1}' | sed 's/G//i')
            free_gb=${avail_gb%.*}
            ;;
        dir|nfs|cifs|glusterfs)
            local storage_path
            storage_path=$(pvesm list "$storage" --output-format json 2>/dev/null \
                | grep -oP '"volid":"\K[^"]+' | head -1 \
                | xargs -I{} pvesm path "{}" 2>/dev/null | xargs dirname)
            [[ -z "$storage_path" || ! -d "$storage_path" ]] && storage_path=$(pvesm status 2>/dev/null | awk -v s="$storage" 'NR>1 && $1==s{print $7; exit}')
            [[ -n "$storage_path" && -d "$storage_path" ]] || die "Could not resolve path for '$storage'"
            local free_kb
            free_kb=$(df -k "$storage_path" 2>/dev/null | awk 'NR==2{print $4}')
            free_gb=$((free_kb / 1024 / 1024))
            ;;
        *)
            die "Unsupported storage type '$storage_type' for space check"
            ;;
    esac

    if [[ "$free_gb" -lt "$required_gb" ]]; then
        die "Insufficient free space on '$storage' for ${label}: ${free_gb}GB available, ${required_gb}GB required"
    fi

    ok "Storage '$storage' has ${free_gb}GB free (required for ${label}: ${required_gb}GB)"
    return 0
}
