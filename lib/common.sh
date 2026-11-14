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

### Function: get_proxmox_major_version
# Detect the major version of the installed Proxmox VE environment.
#
# Outputs:
#   The major version number, or 0 if it cannot be detected.
get_proxmox_major_version() {
    local version_str
    version_str=$(pveversion 2>/dev/null | head -1)
    if [[ -n "$version_str" && "$version_str" =~ pve-manager/([0-9]+)\. ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "0"
    fi
}

### Function: get_first_storage_volid
# Return the first volume ID found on a Proxmox storage, using the
# pvesm output format that is available on this Proxmox VE version.
#
# Arguments:
#   $1 - Storage name.
#
# Outputs:
#   The first volume ID string, or nothing if the storage is empty or
#   the volume cannot be determined.
get_first_storage_volid() {
    local storage="$1"
    local pvesm_out pvesm_rc

    pvesm_out=$(pvesm list "$storage" --output-format json 2>/dev/null)
    pvesm_rc=$?
    if [[ $pvesm_rc -eq 0 ]]; then
        local volid
        volid=$(printf '%s\n' "$pvesm_out" | grep -oP '"volid":"\K[^"]+' | head -1)
        if [[ -n "$volid" ]]; then
            echo "$volid"
            return 0
        fi
    fi

    pvesm_out=$(pvesm list "$storage" 2>/dev/null)
    pvesm_rc=$?
    if [[ $pvesm_rc -eq 0 ]]; then
        local volid
        # Text table output: the first whitespace-delimited token of the first
        # data row (volid strings always contain a storage-identifier colon).
        volid=$(printf '%s\n' "$pvesm_out" | awk '$0 ~ /:/{ print $1; exit }')
        if [[ -n "$volid" ]]; then
            echo "$volid"
            return 0
        fi
    fi

    return 1
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

    if [[ "${ASSUME_YES:-false}" == "true" ]]; then
        warn "${target_type^^} ID $target_id already exists; will overwrite (--yes set)"
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
            local vg_name=""
            # Derive the VG from an existing volume on this storage
            local first_volid vol_path
            first_volid=$(get_first_storage_volid "$storage") || true
            if [[ -n "$first_volid" ]]; then
                vol_path=$(pvesm path "$first_volid" 2>/dev/null) || true
                [[ -n "$vol_path" ]] && vg_name=$(lvm_vg_from_path "$vol_path") || true
            fi
            [[ -z "$vg_name" ]] && vg_name=$(vgs --noheadings -o vg_name 2>/dev/null | head -1 | tr -d ' ')
            [[ -n "$vg_name" ]] || die "Could not determine volume group for '$storage'"
            local free_mb
            free_mb=$(vgs --noheadings --units m -o vg_free "$vg_name" 2>/dev/null | awk '{print $1}' | sed 's/m//i' | cut -d'.' -f1)
            free_gb=$((free_mb / 1024))
            ;;
        zfspool|dir|nfs|cifs|glusterfs)
            # pvesm reports Available (KiB) directly for these storage types;
            # no existing volume on the storage is required.
            local free_kb
            free_kb=$(pvesm status --storage "$storage" 2>/dev/null | awk 'NR==2{print $6}')
            [[ "$free_kb" =~ ^[0-9]+$ ]] || die "Could not determine free space for '$storage'"
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

### Function: lvm_vg_from_path
# Derive the LVM volume-group name from a device path.
#
# Handles /dev/<vg>/<lv>, /dev/mapper/<vg>-<lv> (device-mapper
# double-dash escaping), and /dev/dm-* via dmsetup.
#
# Arguments:
#   $1 - Device path.
#
# Outputs:
#   The VG name to stdout.
#
# Returns:
#   0 on success, 1 if the VG cannot be determined.
lvm_vg_from_path() {
    local path="$1" vg="" name=""
    case "$path" in
        /dev/mapper/*)
            name="${path#/dev/mapper/}"
            ;;
        /dev/dm-*)
            name=$(dmsetup info --noheadings -c -o name "$path" 2>/dev/null | tr -d ' ')
            ;;
        /dev/*/*)
            vg="${path#/dev/}"
            vg="${vg%%/*}"
            printf '%s\n' "$vg"
            return 0
            ;;
        *)
            return 1
            ;;
    esac

    # device-mapper escapes '-' inside names as '--'; the vg/lv separator
    # is a single '-'. Decode escaped dashes, then take the first field.
    if [[ -n "$name" ]]; then
        vg=$(printf '%s' "$name" | sed 's/--/\x01/g; s/-.*//; s/\x01/-/g')
    fi
    [[ -n "$vg" ]] || return 1
    printf '%s\n' "$vg"
}

### Function: storage_cfg_value
# Read a parameter value for a storage from /etc/pve/storage.cfg.
#
# Arguments:
#   $1 - Storage name (e.g., "local-lvm")
#   $2 - Parameter key (e.g., "vgname", "pool", "path")
#
# Outputs:
#   The parameter value to stdout, or nothing if not found.
#
# Returns:
#   0 if a value was printed, 1 otherwise.
storage_cfg_value() {
    local name="$1" key="$2"
    [[ -r /etc/pve/storage.cfg ]] || return 1
    awk -v name="$name" -v key="$key" '
        /^[[:alnum:]_-]+:/ {
            sub(/:$/, "", $1)
            inblock = (NF >= 2 && $2 == name)
        }
        inblock && $1 == key { print $2; exit }
    ' /etc/pve/storage.cfg
}

### Function: storage_target_dir
# Resolve the host directory where disk images for a directory-based
# storage live. With a guest ID, returns <path>/images/<id>.
#
# Arguments:
#   $1 - Storage name.
#   $2 - Optional guest ID for the images/<id> subdirectory.
#
# Outputs:
#   The directory path to stdout.
#
# Returns:
#   0 on success, 1 if it cannot be determined.
storage_target_dir() {
    local storage="$1" guest_id="${2:-}" base="" volid="" vpath=""

    base=$(storage_cfg_value "$storage" path) || base=""
    if [[ -z "$base" ]]; then
        volid=$(get_first_storage_volid "$storage") || true
        if [[ -n "$volid" ]]; then
            vpath=$(pvesm path "$volid" 2>/dev/null) || true
            # Images live under <path>/images/<id>/<file>
            [[ -n "$vpath" ]] && base="${vpath%/images/*}"
        fi
    fi
    [[ -n "$base" ]] || return 1

    if [[ -n "$guest_id" ]]; then
        printf '%s/images/%s\n' "$base" "$guest_id"
    else
        printf '%s\n' "$base"
    fi
}

### Function: storage_vg_name
# Resolve the LVM volume group backing a storage, from storage.cfg
# first, then an existing volume path, then a VG scan.
#
# Arguments:
#   $1 - Storage name.
#
# Outputs:
#   The VG name to stdout.
#
# Returns:
#   0 on success, 1 if it cannot be determined.
storage_vg_name() {
    local storage="$1" vg="" volid="" vpath=""

    vg=$(storage_cfg_value "$storage" vgname) || vg=""
    if [[ -z "$vg" ]]; then
        volid=$(get_first_storage_volid "$storage") || true
        if [[ -n "$volid" ]]; then
            vpath=$(pvesm path "$volid" 2>/dev/null) || true
            [[ -n "$vpath" ]] && vg=$(lvm_vg_from_path "$vpath") || true
        fi
    fi
    [[ -z "$vg" ]] && vg=$(vgs --noheadings -o vg_name 2>/dev/null | head -1 | tr -d ' ')
    [[ -n "$vg" ]] || return 1
    printf '%s\n' "$vg"
}

### Function: storage_zfs_pool
# Resolve the ZFS pool/dataset backing a zfspool storage, from
# storage.cfg first, then an existing volume's parent dataset.
#
# Arguments:
#   $1 - Storage name.
#
# Outputs:
#   The ZFS pool/dataset to stdout.
#
# Returns:
#   0 on success, 1 if it cannot be determined.
storage_zfs_pool() {
    local storage="$1" pool="" volid="" vpath=""

    pool=$(storage_cfg_value "$storage" pool) || pool=""
    if [[ -z "$pool" ]]; then
        volid=$(get_first_storage_volid "$storage") || true
        if [[ -n "$volid" ]]; then
            vpath=$(pvesm path "$volid" 2>/dev/null) || true
            vpath="${vpath#/dev/zvol/}"
            [[ -n "$vpath" ]] && pool="${vpath%/*}"
        fi
    fi
    [[ -z "$pool" ]] && pool=$(zpool list -H -o name 2>/dev/null | head -1)
    [[ -n "$pool" ]] || return 1
    printf '%s\n' "$pool"
}

### Function: stop_guest_gracefully
# Ask a guest to shut down (qm/pct shutdown), poll until stopped, and
# fall back to a hard stop after the timeout.
#
# Arguments:
#   $1 - Guest type: "vm" or "ct"
#   $2 - Guest ID
#   $3 - Grace period in seconds before forcing a stop (default: 60)
#
# Returns:
#   0 once the guest is stopped.
stop_guest_gracefully() {
    local type="$1" id="$2" timeout="${3:-60}"
    local status_cmd shutdown_cmd stop_cmd
    case "$type" in
        vm)
            status_cmd="qm status"; shutdown_cmd="qm shutdown"; stop_cmd="qm stop" ;;
        ct|lxc)
            status_cmd="pct status"; shutdown_cmd="pct shutdown"; stop_cmd="pct stop" ;;
        *)
            warn "stop_guest_gracefully: unknown guest type '$type'"
            return 1
            ;;
    esac

    $shutdown_cmd "$id" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    local waited=0 state=""
    while [[ "$waited" -lt "$timeout" ]]; do
        state=$($status_cmd "$id" 2>/dev/null | awk '{print $2}')
        [[ "$state" == "stopped" ]] && return 0
        sleep 2
        waited=$((waited + 2))
    done
    warn "Graceful shutdown of $type $id timed out after ${timeout}s; forcing stop."
    $stop_cmd "$id" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    sleep 2
}
